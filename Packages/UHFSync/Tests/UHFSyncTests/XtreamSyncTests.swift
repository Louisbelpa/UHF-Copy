import XCTest
import UHFCore
import UHFSources
import UHFStore
@testable import UHFSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: String] = [:]

    func stub(action: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        responses[action] = body
    }

    private func body(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "action" }?.value ?? ""
        return responses[action]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body = body(for: url) ?? "[]"
        return (Data(body.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class XtreamSyncTests: XCTestCase {

    private func makeService(channelCount: Int = 3,
                             maxConnections: Int = 2,
                             expiresIn: TimeInterval = 90 * 86_400)
        throws -> (UHFDatabase, StubTransport, PlaylistSyncService, PlaylistRecord) {

        let database = try UHFDatabase.inMemory()
        let playlist = PlaylistRecord(id: "p1", name: "Mon abonnement", kind: .xtream,
                                      url: URL(string: "http://srv:8080")!,
                                      credentialsRef: "keychain-ref")
        try database.writer.write { try playlist.insert($0) }

        let transport = StubTransport()
        transport.stub(action: "", body: """
            {"user_info":{"username":"u","auth":1,"status":"Active",
             "exp_date":"\(Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970))",
             "max_connections":"\(maxConnections)","active_cons":"0",
             "allowed_output_formats":["m3u8","ts"]}}
            """)
        let streams = (0..<channelCount).map {
            """
            {"num":\($0),"name":"Chaîne \($0)","stream_id":\($0 + 1),
             "epg_channel_id":"ch\($0).fr","category_id":"1","tv_archive":0}
            """
        }.joined(separator: ",")
        transport.stub(action: "get_live_streams", body: "[\(streams)]")
        transport.stub(action: "get_vod_streams", body: """
            [{"num":1,"name":"Inception (2010)","stream_id":900,"container_extension":"mkv"}]
            """)
        transport.stub(action: "get_series", body: """
            [{"num":1,"name":"The Wire","series_id":42}]
            """)

        let service = PlaylistSyncService(
            database: database,
            downloader: FailingDownloader(),
            transport: transport,
            credentialsProvider: { _ in (username: "u", password: "p") })

        return (database, transport, service, playlist)
    }

    /// Le guide n'est pas le sujet ici : son échec doit rester sans conséquence.
    private struct FailingDownloader: FileDownloading {
        struct Unavailable: Error, LocalizedError {
            var errorDescription: String? { "guide non testé ici" }
        }
        func download(from url: URL, headers: [String: String],
                      progress: @Sendable (Double?) -> Void) async throws -> URL {
            throw Unavailable()
        }
    }

    func testImportsChannelsMoviesAndSeries() async throws {
        let (database, _, service, playlist) = try makeService()
        let report = try await service.refresh(playlist: playlist)

        XCTAssertEqual(report.channels.added, 3)
        XCTAssertEqual(report.movies?.added, 1)
        XCTAssertEqual(report.series?.added, 1)

        XCTAssertEqual(try ChannelStore(database).count(playlistID: "p1"), 3)
        XCTAssertEqual(try VODStore(database).movieCount(playlistID: "p1"), 1)

        // Le format HLS est disponible : les URLs doivent le privilégier, pour rester
        // sur AVPlayer et conserver PiP, AirPlay et HDR.
        let first = try XCTUnwrap(ChannelStore(database).channels(playlistID: "p1").first)
        XCTAssertTrue(first.url.hasSuffix(".m3u8"), first.url)
    }

    func testMissingCredentialsFailFast() async throws {
        let database = try UHFDatabase.inMemory()
        let playlist = PlaylistRecord(id: "p1", name: "Source", kind: .xtream,
                                      url: URL(string: "http://srv:8080")!)
        try await database.writer.write { try playlist.insert($0) }

        do {
            _ = try await PlaylistSyncService(database: database,
                                              downloader: FailingDownloader(),
                                              transport: StubTransport())
                .refresh(playlist: playlist)
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertEqual(error as? PlaylistSyncService.Failure, .missingCredentials)
        }
    }

    func testExpiredAccountIsReportedBeforeAnyDownload() async throws {
        let (database, transport, service, playlist) = try makeService()
        transport.stub(action: "", body: #"{"user_info":{"auth":1,"status":"Active","exp_date":"1000000000"}}"#)

        do {
            _ = try await service.refresh(playlist: playlist)
            XCTFail("aurait dû échouer")
        } catch {
            guard case .accountExpired = error as? XtreamError else {
                return XCTFail("attendu accountExpired, reçu \(error)")
            }
        }
        XCTAssertEqual(try ChannelStore(database).count(playlistID: "p1"), 0,
                       "rien n'a été écrit")
    }

    func testTruncatedResponseIsRefusedBeforeOverwritingTheCatalogue() async throws {
        let (database, transport, service, playlist) = try makeService(channelCount: 500)
        _ = try await service.refresh(playlist: playlist)
        XCTAssertEqual(try ChannelStore(database).count(playlistID: "p1"), 500)

        // Le serveur, surchargé, ne renvoie plus que 10 chaînes — avec un code 200.
        transport.stub(action: "get_live_streams", body: """
            [{"num":1,"name":"Chaîne 0","stream_id":1,"category_id":"1"}]
            """)
        do {
            _ = try await service.refresh(playlist: playlist)
            XCTFail("aurait dû refuser")
        } catch {
            guard case .suspiciousResult = error as? PlaylistSyncService.Failure else {
                return XCTFail("attendu suspiciousResult, reçu \(error)")
            }
        }
        XCTAssertEqual(try ChannelStore(database).count(playlistID: "p1"), 500,
                       "le catalogue précédent doit être intact")
    }

    func testSubscriptionWarningsAreSurfaced() async throws {
        let (_, _, service, playlist) = try makeService(maxConnections: 1,
                                                        expiresIn: 3 * 86_400)
        let report = try await service.refresh(playlist: playlist)

        XCTAssertTrue(report.warnings.contains { $0.contains("une connexion") })
        XCTAssertTrue(report.warnings.contains { $0.contains("expire") })
    }

    func testVODFailureDoesNotBlockChannels() async throws {
        let (database, transport, service, playlist) = try makeService()
        transport.stub(action: "get_vod_streams", body: "pas du JSON")

        let report = try await service.refresh(playlist: playlist)
        XCTAssertEqual(report.channels.added, 3, "les chaînes restent l'essentiel")
        XCTAssertNil(report.movies)
        XCTAssertTrue(report.warnings.contains { $0.contains("Films indisponibles") })
        XCTAssertEqual(try ChannelStore(database).count(playlistID: "p1"), 3)
    }
}
