import XCTest
import UHFCore
@testable import UHFSources

final class XtreamCredentialsTests: XCTestCase {

    func testParsesFullGetPhpPlaylistURL() throws {
        let credentials = try XCTUnwrap(XtreamClient.Credentials(
            pastedURL: "http://monserveur.tv:8080/get.php?username=bob&password=s3cret&type=m3u_plus&output=ts"))
        XCTAssertEqual(credentials.baseURL.absoluteString, "http://monserveur.tv:8080")
        XCTAssertEqual(credentials.username, "bob")
        XCTAssertEqual(credentials.password, "s3cret")
    }

    func testParsesPlayerAPIURL() throws {
        let credentials = try XCTUnwrap(XtreamClient.Credentials(
            pastedURL: "https://srv.example.com/player_api.php?username=u&password=p"))
        XCTAssertEqual(credentials.baseURL.absoluteString, "https://srv.example.com")
    }

    func testAddsMissingScheme() throws {
        let credentials = try XCTUnwrap(XtreamClient.Credentials(
            pastedURL: "srv.example.com:8080/get.php?username=u&password=p"))
        XCTAssertEqual(credentials.baseURL.scheme, "http")
    }

    func testRejectsURLWithoutCredentials() {
        XCTAssertNil(XtreamClient.Credentials(pastedURL: "http://srv.example.com/get.php"))
        XCTAssertNil(XtreamClient.Credentials(pastedURL: "pas une url"))
    }
}

final class XtreamClientTests: XCTestCase {

    private let credentials = XtreamClient.Credentials(
        baseURL: URL(string: "http://srv:8080")!, username: "u", password: "p")

    // MARK: - Compte

    func testAccountParsesMixedTypesAndFormats() async throws {
        let stub = StubTransport()
        stub.stub(action: "", body: """
        {"user_info":{"username":"u","auth":1,"status":"Active","exp_date":"1893456000",
        "is_trial":"0","active_cons":"1","max_connections":"2",
        "allowed_output_formats":["m3u8","ts","rtmp"]},
        "server_info":{"timezone":"Europe/Paris","timestamp_now":1700000000}}
        """)
        let account = try await XtreamClient(credentials: credentials, transport: stub).account()

        XCTAssertTrue(account.isAuthenticated)
        XCTAssertEqual(account.maxConnections, 2)
        XCTAssertEqual(account.activeConnections, 1)
        XCTAssertFalse(account.isTrial)
        XCTAssertEqual(account.serverTimezone, "Europe/Paris")
        XCTAssertEqual(account.preferredLiveFormat, .m3u8,
                       "HLS disponible : on doit rester sur AVPlayer")
    }

    func testFallsBackToTSWhenHLSUnavailable() async throws {
        let stub = StubTransport()
        stub.stub(action: "", body: """
        {"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts"]}}
        """)
        let account = try await XtreamClient(credentials: credentials, transport: stub).account()
        XCTAssertEqual(account.preferredLiveFormat, .ts)
    }

    func testRejectsBadCredentials() async {
        let stub = StubTransport()
        stub.stub(action: "", body: #"{"user_info":{"auth":0}}"#)
        do {
            _ = try await XtreamClient(credentials: credentials, transport: stub).account()
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertEqual(error as? XtreamError, .invalidCredentials)
        }
    }

    func testDetectsExpiredSubscription() async {
        let stub = StubTransport()
        stub.stub(action: "", body: """
        {"user_info":{"auth":1,"status":"Active","exp_date":"1000000000"}}
        """)
        do {
            _ = try await XtreamClient(credentials: credentials, transport: stub).account()
            XCTFail("aurait dû échouer")
        } catch {
            guard case .accountExpired = error as? XtreamError else {
                return XCTFail("attendu accountExpired, reçu \(error)")
            }
        }
    }

    func testMapsHTTP403ToCredentialError() async {
        let stub = StubTransport()
        stub.stub(action: "", status: 403, body: "forbidden")
        do {
            _ = try await XtreamClient(credentials: credentials, transport: stub).account()
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertEqual(error as? XtreamError, .invalidCredentials)
        }
    }

    func testErrorMessagesAreUserFacing() {
        XCTAssertTrue(XtreamError.maxConnectionsReached(2).errorDescription?.contains("2") ?? false)
        XCTAssertFalse(XtreamError.invalidCredentials.errorDescription?.isEmpty ?? true)
    }

    // MARK: - Chaînes live

    func testLiveChannelsBuildPlayableURLsAndCatchup() async throws {
        let stub = StubTransport()
        stub.stub(action: "get_live_streams", body: """
        [{"num":1,"name":"TF1 HD","stream_id":1234,"stream_icon":"http://srv/tf1.png",
          "epg_channel_id":"TF1.fr","category_id":"5","tv_archive":1,"tv_archive_duration":7},
         {"num":2,"name":"M6","stream_id":"5678","stream_icon":"","epg_channel_id":"",
          "category_id":"5","tv_archive":0,"tv_archive_duration":"0"}]
        """)
        let channels = try await XtreamClient(credentials: credentials, transport: stub)
            .liveChannels(format: .m3u8)

        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].url.absoluteString, "http://srv:8080/live/u/p/1234.m3u8")
        XCTAssertEqual(channels[0].tvgID, "TF1.fr")
        XCTAssertEqual(channels[0].catchup, .xtream)
        XCTAssertEqual(channels[0].catchupDays, 7)
        XCTAssertTrue(channels[0].supportsCatchup)

        // stream_id en chaîne, icône et epg vides : tolérés sans perdre la chaîne.
        XCTAssertEqual(channels[1].url.absoluteString, "http://srv:8080/live/u/p/5678.m3u8")
        XCTAssertNil(channels[1].logoURL)
        XCTAssertNil(channels[1].tvgID)
        XCTAssertFalse(channels[1].supportsCatchup)
    }

    func testDirectSourceOverridesCanonicalURL() async throws {
        let stub = StubTransport()
        stub.stub(action: "get_live_streams", body: """
        [{"num":1,"name":"A","stream_id":1,"direct_source":"http://autre/flux.m3u8"}]
        """)
        let channels = try await XtreamClient(credentials: credentials, transport: stub)
            .liveChannels(format: .ts)
        XCTAssertEqual(channels[0].url.absoluteString, "http://autre/flux.m3u8")
    }

    // MARK: - VOD et séries

    func testMoviesExtractYearFromTitle() async throws {
        let stub = StubTransport()
        stub.stub(action: "get_vod_streams", body: """
        [{"num":1,"name":"Inception (2010)","stream_id":99,"rating":"8,8",
          "container_extension":"mkv","category_id":"3"}]
        """)
        let movies = try await XtreamClient(credentials: credentials, transport: stub).movies()
        XCTAssertEqual(movies[0].title, "Inception")
        XCTAssertEqual(movies[0].year, 2010)
        XCTAssertEqual(try XCTUnwrap(movies[0].rating), 8.8, accuracy: 0.001,
                       "note à virgule décimale")
        XCTAssertEqual(movies[0].containerExtension, "mkv")
    }

    func testEpisodesAreFlattenedAndSorted() async throws {
        let stub = StubTransport()
        stub.stub(action: "get_series_info", body: """
        {"seasons":[],"info":{},"episodes":{
          "2":[{"id":"21","episode_num":"1","title":"S2E1","container_extension":"mkv",
                "info":{"duration_secs":2700}}],
          "1":[{"id":"12","episode_num":2,"title":"S1E2","container_extension":"mp4"},
               {"id":"11","episode_num":1,"title":"S1E1","container_extension":"mp4","season":0}]}}
        """)
        let episodes = try await XtreamClient(credentials: credentials, transport: stub)
            .episodes(seriesID: "7")

        XCTAssertEqual(episodes.map { "\($0.season)x\($0.number)" }, ["1x1", "1x2", "2x1"])
        XCTAssertEqual(episodes[0].title, "S1E1")
        XCTAssertEqual(episodes[2].durationSeconds, 2700)
    }

    func testShortEPGDecodesBase64Titles() async throws {
        let title = Data("Le 20 heures".utf8).base64EncodedString()
        let stub = StubTransport()
        stub.stub(action: "get_short_epg", body: """
        {"epg_listings":[{"channel_id":"TF1.fr","title":"\(title)",
          "description":"","start_timestamp":"1700000000","stop_timestamp":"1700003600"}]}
        """)
        let programmes = try await XtreamClient(credentials: credentials, transport: stub)
            .shortEPG(streamID: "1")

        XCTAssertEqual(programmes.count, 1)
        XCTAssertEqual(programmes[0].title, "Le 20 heures")
        XCTAssertEqual(programmes[0].duration, 3600)
    }

    func testProgrammesWithoutTimestampsAreDropped() async throws {
        let stub = StubTransport()
        stub.stub(action: "get_short_epg", body: """
        {"epg_listings":[{"channel_id":"x","title":"","start_timestamp":"0","stop_timestamp":"0"}]}
        """)
        let programmes = try await XtreamClient(credentials: credentials, transport: stub)
            .shortEPG(streamID: "1")
        XCTAssertTrue(programmes.isEmpty)
    }

    // MARK: - URLs

    func testStreamAndEPGURLs() {
        let client = XtreamClient(credentials: credentials, transport: StubTransport())
        XCTAssertEqual(client.movieURL(streamID: "42", containerExtension: "mkv").absoluteString,
                       "http://srv:8080/movie/u/p/42.mkv")
        XCTAssertEqual(client.episodeURL(episodeID: "7", containerExtension: "mp4").absoluteString,
                       "http://srv:8080/series/u/p/7.mp4")
        XCTAssertEqual(client.epgURL.absoluteString,
                       "http://srv:8080/xmltv.php?username=u&password=p")
    }

    func testTimeshiftURLFormat() {
        let client = XtreamClient(credentials: credentials, transport: StubTransport())
        let start = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
        let url = client.timeshiftURL(streamID: "1234", start: start, duration: 3600)
        XCTAssertTrue(url.absoluteString.contains("start=2023-11-14:22-13"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("duration=60"))
        XCTAssertTrue(url.absoluteString.contains("stream=1234"))
    }

    func testCategoryFilterIsPassedThrough() async throws {
        let stub = StubTransport()
        stub.stub(action: "get_live_streams", body: "[]")
        _ = try await XtreamClient(credentials: credentials, transport: stub)
            .liveChannels(categoryID: "12", format: .ts)
        XCTAssertTrue(stub.requestedURLs.last!.absoluteString.contains("category_id=12"))
    }
}
