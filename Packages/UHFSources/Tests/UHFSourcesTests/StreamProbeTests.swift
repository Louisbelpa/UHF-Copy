import XCTest
import UHFCore
@testable import UHFSources
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StreamProbeOfflineTests: XCTestCase {

    func testExtensionRouting() {
        XCTAssertEqual(StreamProbe.engine(forExtension: "m3u8"), .avPlayer)
        XCTAssertEqual(StreamProbe.engine(forExtension: "M3U8"), .avPlayer)
        XCTAssertEqual(StreamProbe.engine(forExtension: "mp4"), .avPlayer)
        XCTAssertEqual(StreamProbe.engine(forExtension: "ts"), .vlcKit)
        XCTAssertEqual(StreamProbe.engine(forExtension: "mkv"), .vlcKit)
        XCTAssertNil(StreamProbe.engine(forExtension: ""), "extension absente : non concluant")
        XCTAssertNil(StreamProbe.engine(forExtension: "php"))
    }

    func testContentTypeRouting() {
        XCTAssertEqual(StreamProbe.engine(forContentType: "application/vnd.apple.mpegurl"), .avPlayer)
        XCTAssertEqual(StreamProbe.engine(forContentType: "application/x-mpegURL; charset=utf-8"),
                       .avPlayer, "paramètres et casse doivent être tolérés")
        XCTAssertEqual(StreamProbe.engine(forContentType: "video/mp2t"), .vlcKit)
        XCTAssertEqual(StreamProbe.engine(forContentType: "video/x-matroska"), .vlcKit)
        XCTAssertNil(StreamProbe.engine(forContentType: "application/octet-stream"),
                     "type générique : ne doit pas trancher")
    }

    func testMagicBytesRecogniseHLS() {
        let playlist = Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)
        XCTAssertEqual(StreamProbe.engine(forMagicBytes: playlist), .avPlayer)

        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(playlist)
        XCTAssertEqual(StreamProbe.engine(forMagicBytes: withBOM), .avPlayer)
    }

    func testMagicBytesRecogniseMPEGTS() {
        // Octet de synchronisation 0x47 toutes les 188 positions.
        var packet = Data([0x47])
        packet.append(Data(repeating: 0x00, count: 187))
        packet.append(Data([0x47]))
        packet.append(Data(repeating: 0x00, count: 187))
        XCTAssertEqual(StreamProbe.engine(forMagicBytes: packet), .vlcKit)
    }

    func testMagicBytesRecogniseMatroskaAndMP4() {
        var matroska = Data([0x1A, 0x45, 0xDF, 0xA3])
        matroska.append(Data(repeating: 0, count: 32))
        XCTAssertEqual(StreamProbe.engine(forMagicBytes: matroska), .vlcKit)

        var mp4 = Data([0x00, 0x00, 0x00, 0x20])
        mp4.append(Data("ftypisom".utf8))
        XCTAssertEqual(StreamProbe.engine(forMagicBytes: mp4), .avPlayer)
    }

    func testMagicBytesInconclusiveOnGarbage() {
        XCTAssertNil(StreamProbe.engine(forMagicBytes: Data()))
        XCTAssertNil(StreamProbe.engine(forMagicBytes: Data([0x01, 0x02, 0x03, 0x04])))
    }

    func testIsolatedSyncByteIsNotEnoughForMPEGTS() {
        // Un seul 0x47 en tête peut être fortuit : la seconde occurrence à 188 fait foi.
        var data = Data([0x47])
        data.append(Data(repeating: 0x11, count: 300))
        XCTAssertNil(StreamProbe.engine(forMagicBytes: data))
    }
}

/// Transport qui rend un corps et des en-têtes arbitraires, pour éprouver la cascade.
private final class BodyTransport: HTTPTransport, @unchecked Sendable {
    private let body: Data
    private let headers: [String: String]
    private let status: Int
    private let shouldFail: Bool
    private(set) var lastRequest: URLRequest?

    init(body: Data = Data(), headers: [String: String] = [:],
         status: Int = 200, shouldFail: Bool = false) {
        self.body = body
        self.headers = headers
        self.status = status
        self.shouldFail = shouldFail
    }

    private func record(_ request: URLRequest) { lastRequest = request }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        if shouldFail { throw URLError(.cannotConnectToHost) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status,
                                      httpVersion: nil, headerFields: headers)!)
    }
}

final class StreamProbeNetworkTests: XCTestCase {

    func testExtensionShortCircuitsBeforeAnyRequest() async {
        let transport = BodyTransport()
        let outcome = await StreamProbe(transport: transport)
            .probe(URL(string: "http://srv/live/u/p/1.m3u8")!)

        XCTAssertEqual(outcome.engine, .avPlayer)
        XCTAssertEqual(outcome.reason, .fileExtension)
        XCTAssertNil(transport.lastRequest, "aucune requête ne doit partir")
    }

    func testMagicBytesWinOverALyingContentType() async {
        // Le serveur annonce du HLS mais sert du MPEG-TS : les octets font foi.
        var packet = Data([0x47])
        packet.append(Data(repeating: 0x00, count: 187))
        packet.append(Data([0x47]))
        packet.append(Data(repeating: 0x00, count: 187))

        let transport = BodyTransport(body: packet,
                                      headers: ["Content-Type": "application/x-mpegURL"])
        let outcome = await StreamProbe(transport: transport)
            .probe(URL(string: "http://srv/stream.php?id=1")!)

        XCTAssertEqual(outcome.engine, .vlcKit)
        XCTAssertEqual(outcome.reason, .magicBytes)
    }

    func testFallsBackToContentTypeWhenBytesAreInconclusive() async {
        let transport = BodyTransport(body: Data([0x01, 0x02, 0x03, 0x04]),
                                      headers: ["content-type": "video/mp4"])
        let outcome = await StreamProbe(transport: transport)
            .probe(URL(string: "http://srv/stream.php?id=1")!)

        XCTAssertEqual(outcome.engine, .avPlayer)
        XCTAssertEqual(outcome.reason, .contentType)
        XCTAssertEqual(outcome.contentType, "video/mp4", "en-tête en minuscules accepté")
    }

    func testRequestsOnlyTheFirstKilobytes() async {
        let transport = BodyTransport(body: Data(repeating: 0, count: 8))
        _ = await StreamProbe(transport: transport).probe(URL(string: "http://srv/x.php")!)

        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Range"), "bytes=0-2047",
                       "ouvrir le flux entier consommerait une connexion de l'abonnement")
    }

    func testCustomHeadersArePassedThrough() async {
        let transport = BodyTransport(body: Data(repeating: 0, count: 8))
        _ = await StreamProbe(transport: transport)
            .probe(URL(string: "http://srv/x.php")!, headers: ["User-Agent": "VLC/3.0"])

        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "User-Agent"), "VLC/3.0")
    }

    func testNetworkFailureFallsBackToTheMorePermissiveEngine() async {
        let transport = BodyTransport(shouldFail: true)
        let outcome = await StreamProbe(transport: transport)
            .probe(URL(string: "http://srv/x.php")!)

        XCTAssertEqual(outcome.engine, .vlcKit)
        XCTAssertEqual(outcome.reason, .fallback)
    }
}
