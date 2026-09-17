import XCTest
import UHFCore
import UHFSources
import UHFStore
@testable import UHFSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Téléchargeur bouchonné : sert un contenu figé par URL, en écrivant un vrai fichier
/// pour que les parseurs empruntent exactement le même chemin qu'en production.
/// Collecteur de phases utilisable depuis une fermeture `@Sendable`.
private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

private final class StubDownloader: FileDownloading, @unchecked Sendable {
    private var contents: [String: Data] = [:]
    private(set) var requestedURLs: [URL] = []
    private(set) var lastHeaders: [String: String] = [:]
    var failingURLs: Set<String> = []

    struct NotFound: Error {}
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "serveur injoignable" }
    }

    func stub(_ url: String, _ text: String) { contents[url] = Data(text.utf8) }
    func stub(_ url: String, data: Data) { contents[url] = data }

    func download(from url: URL, headers: [String: String],
                  progress: @Sendable (Double?) -> Void) async throws -> URL {
        requestedURLs.append(url)
        lastHeaders = headers
        if failingURLs.contains(url.absoluteString) { throw Refused() }
        guard let data = contents[url.absoluteString] else { throw NotFound() }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-stub-\(UUID().uuidString)")
        try data.write(to: destination)
        progress(1)
        return destination
    }
}

final class M3USyncTests: XCTestCase {

    private let playlistURL = "http://srv/get.php?username=u&password=p"
    private let epgURL = "http://srv/xmltv.php?username=u&password=p"

    private var playlistM3U: String {
        """
        #EXTM3U url-tvg="\(epgURL)"
        #EXTINF:-1 tvg-id="TF1.fr" tvg-logo="http://srv/tf1.png" group-title="FR | Généralistes",FR | TF1 HD
        http://srv/live/u/p/1.m3u8
        #EXTINF:-1 tvg-id="M6.fr" group-title="FR | Généralistes",FR | M6 HD
        http://srv/live/u/p/2.ts
        #EXTINF:-1 group-title="FR | Sport",beIN SPORTS 1
        http://srv/live/u/p/3.ts
        #EXTINF:-1 group-title="FR | XXX",Adulte
        http://srv/live/u/p/4.ts
        """
    }

    private var guideXML: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"

        let now = Date()
        func stamp(_ offset: TimeInterval) -> String {
            formatter.string(from: now.addingTimeInterval(offset)) + " +0000"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="TF1.fr"><display-name lang="fr">TF1</display-name></channel>
          <channel id="M6.fr"><display-name lang="fr">M6</display-name></channel>
          <programme start="\(stamp(-1800))" stop="\(stamp(1800))" channel="TF1.fr">
            <title lang="fr">Le 20 heures</title><desc lang="fr">Actualité.</desc>
          </programme>
          <programme start="\(stamp(1800))" stop="\(stamp(5400))" channel="TF1.fr">
            <title lang="fr">Film du soir</title>
          </programme>
          <programme start="\(stamp(-600))" stop="\(stamp(3000))" channel="M6.fr">
            <title lang="fr">Le 19:45</title>
          </programme>
        </tv>
        """
    }

    private func makeService() throws -> (UHFDatabase, StubDownloader, PlaylistSyncService, PlaylistRecord) {
        let database = try UHFDatabase.inMemory()
        let playlist = PlaylistRecord(id: "p1", name: "Ma source", kind: .m3u,
                                      url: URL(string: playlistURL)!)
        try database.writer.write { try playlist.insert($0) }

        let downloader = StubDownloader()
        downloader.stub(playlistURL, playlistM3U)
        downloader.stub(epgURL, guideXML)

        return (database, downloader,
                PlaylistSyncService(database: database, downloader: downloader),
                playlist)
    }

    // MARK: - Chaîne complète

    func testFullRefreshImportsChannelsGuideAndLinks() async throws {
        let (database, _, service, playlist) = try makeService()

        let phases = PhaseLog()
        let report = try await service.refresh(playlist: playlist) { phase in
            phases.append(phase.label)
        }

        // Chaînes
        XCTAssertEqual(report.channels.added, 4)
        XCTAssertEqual(report.channels.removed, 0)

        let channels = ChannelStore(database)
        XCTAssertEqual(try channels.count(playlistID: "p1"), 4)
        XCTAssertEqual(try channels.channels(playlistID: "p1").count, 3,
                       "la catégorie adulte est filtrée par défaut")

        // Recherche opérationnelle immédiatement après l'import
        XCTAssertEqual(try channels.search("tf1").first?.name, "FR | TF1 HD")
        XCTAssertEqual(try channels.search("bein").count, 1)

        // Guide
        XCTAssertEqual(report.epg?.added, 3)
        XCTAssertNotNil(report.epgMatchRate)

        // Now/next de bout en bout : c'est ce que la liste de chaînes affiche.
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "FR | TF1 HD")
        let nowNext = try EPGStore(database).nowNext(channelKeys: [tf1], playlistID: "p1")
        XCTAssertEqual(nowNext[tf1]?.current?.title, "Le 20 heures")
        XCTAssertEqual(nowNext[tf1]?.next?.title, "Film du soir")

        XCTAssertTrue(phases.all.contains { $0.contains("guide") })
        XCTAssertFalse(report.warnings.contains { $0.contains("Guide indisponible") })
    }

    func testEPGURLDeclaredByThePlaylistIsDiscoveredAndStored() async throws {
        let (database, downloader, service, playlist) = try makeService()
        XCTAssertNil(playlist.epgURL, "la playlist ne connaît pas encore son guide")

        _ = try await service.refresh(playlist: playlist)

        XCTAssertTrue(downloader.requestedURLs.map(\.absoluteString).contains(epgURL))
        let stored = try await database.reader.read { try PlaylistRecord.fetchOne($0, key: "p1") }
        XCTAssertEqual(stored?.epgURL, epgURL, "retenu pour les rafraîchissements suivants")
    }

    func testMatchRateAndManualMappingHint() async throws {
        let (_, _, service, playlist) = try makeService()
        let report = try await service.refresh(playlist: playlist)

        // 2 chaînes sur 4 ont une correspondance dans le guide.
        XCTAssertEqual(try XCTUnwrap(report.epgMatchRate), 0.5, accuracy: 0.01)
        XCTAssertTrue(report.suggestsManualEPGMapping)
    }

    // MARK: - Robustesse

    func testGuideFailureDoesNotFailTheChannelImport() async throws {
        let (database, downloader, service, playlist) = try makeService()
        downloader.failingURLs = [epgURL]

        let report = try await service.refresh(playlist: playlist)

        XCTAssertEqual(report.channels.added, 4, "les chaînes doivent être importées")
        XCTAssertNil(report.epg)
        XCTAssertTrue(report.warnings.contains { $0.contains("Guide indisponible") })
        XCTAssertEqual(try ChannelStore(database).count(playlistID: "p1"), 4)
    }

    func testEmptyPlaylistIsRejectedRatherThanWipingTheCatalogue() async throws {
        let (database, downloader, service, playlist) = try makeService()
        _ = try await service.refresh(playlist: playlist)
        XCTAssertEqual(try ChannelStore(database).count(playlistID: "p1"), 4)

        downloader.stub(playlistURL, "#EXTM3U\n")
        do {
            _ = try await service.refresh(playlist: playlist)
            XCTFail("un import vide doit échouer")
        } catch {
            XCTAssertTrue(error is PlaylistSyncService.Failure)
        }
    }

    func testUserDataSurvivesARealRefreshCycle() async throws {
        let (database, downloader, service, playlist) = try makeService()
        _ = try await service.refresh(playlist: playlist)

        let library = LibraryStore(database)
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "FR | TF1 HD")
        try library.setFavorite(true, key: tf1, kind: .channel)
        try library.setOverride(ChannelOverrideRecord(channelKey: tf1, customName: "La Une"))

        // Le fournisseur renomme la chaîne, change son URL, et retire beIN.
        downloader.stub(playlistURL, """
        #EXTM3U url-tvg="\(epgURL)"
        #EXTINF:-1 tvg-id="TF1.fr" group-title="FR | Généralistes",TF1 Ultra HD
        http://srv/live/u/p/999.m3u8
        #EXTINF:-1 tvg-id="M6.fr" group-title="FR | Généralistes",FR | M6 HD
        http://srv/live/u/p/2.ts
        #EXTINF:-1 group-title="FR | XXX",Adulte
        http://srv/live/u/p/4.ts
        """)

        let report = try await service.refresh(playlist: playlist)
        XCTAssertEqual(report.channels.removed, 1, "beIN")
        XCTAssertEqual(report.channels.updated, 3)

        XCTAssertTrue(try library.isFavorite(tf1), "le favori survit")
        XCTAssertEqual(try library.override(for: tf1)?.customName, "La Une")
        XCTAssertEqual(try ChannelStore(database).channel(key: tf1)?.url,
                       "http://srv/live/u/p/999.m3u8", "mais l'URL suit la source")
    }

    func testManualEPGMappingIsNotUndoneByARefresh() async throws {
        let (database, _, service, playlist) = try makeService()
        _ = try await service.refresh(playlist: playlist)

        let epg = EPGStore(database)
        let bein = StableKey.channel(playlistID: "p1", tvgID: nil, name: "beIN SPORTS 1")
        try epg.setManualLink(channelKey: bein, xmltvID: "M6.fr", playlistID: "p1")

        _ = try await service.refresh(playlist: playlist)

        XCTAssertEqual(try epg.link(for: bein, playlistID: "p1")?.xmltvId, "M6.fr")
        XCTAssertTrue(try XCTUnwrap(epg.link(for: bein, playlistID: "p1")).isManual)
    }

    func testCustomHeadersReachTheDownloader() async throws {
        let database = try UHFDatabase.inMemory()
        let playlist = PlaylistRecord(id: "p1", name: "Source", kind: .m3u,
                                      url: URL(string: playlistURL)!,
                                      userAgent: "VLC/3.0.20", referer: "http://srv/")
        try await database.writer.write { try playlist.insert($0) }

        let downloader = StubDownloader()
        downloader.stub(playlistURL, playlistM3U)
        downloader.stub(epgURL, guideXML)

        _ = try await PlaylistSyncService(database: database, downloader: downloader)
            .refresh(playlist: playlist)

        XCTAssertEqual(downloader.lastHeaders["User-Agent"], "VLC/3.0.20")
        XCTAssertEqual(downloader.lastHeaders["Referer"], "http://srv/")
    }

    func testGzippedGuideIsHandled() async throws {
        let (database, downloader, service, playlist) = try makeService()

        // Écrit un vrai .gz, pour exercer la décompression en flux.
        let directory = FileManager.default.temporaryDirectory
        let plain = directory.appendingPathComponent("uhf-\(UUID().uuidString).xml")
        let gzipped = directory.appendingPathComponent("uhf-\(UUID().uuidString).xml.gz")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: gzipped)
        }
        try guideXML.write(to: plain, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", "gzip -c '\(plain.path)' > '\(gzipped.path)'"]
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "gzip indisponible")

        downloader.stub(epgURL, data: try Data(contentsOf: gzipped))
        let report = try await service.refresh(playlist: playlist)

        XCTAssertEqual(report.epg?.added, 3)
        XCTAssertEqual(try EPGStore(database).programmeCount(playlistID: "p1"), 3)
    }

    func testExpiredProgrammesArePurgedOnEachRefresh() async throws {
        let (database, _, service, playlist) = try makeService()
        _ = try await service.refresh(playlist: playlist)

        // Un vieux programme glissé directement en base doit disparaître au tour suivant.
        try await database.writer.write { db in
            let channelId = try Int64.fetchOne(db, sql: "SELECT id FROM epgChannels LIMIT 1")!
            try db.execute(sql: """
                INSERT INTO programmes (epgChannelId, startAt, endAt, title, syncToken)
                VALUES (?, ?, ?, 'Périmé', 'x')
                """, arguments: [channelId,
                                 Date().addingTimeInterval(-10 * 86_400).timeIntervalSince1970,
                                 Date().addingTimeInterval(-9 * 86_400).timeIntervalSince1970])
        }
        _ = try await service.refresh(playlist: playlist)

        let titles = try await database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM programmes")
        }
        XCTAssertFalse(titles.contains("Périmé"))
    }
}
