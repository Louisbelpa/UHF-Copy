import XCTest
import UHFCore
@testable import UHFStore

/// Vérifie les cibles de `docs/PLAN.md` §6 sur la couche de persistance.
///
/// Seuils volontairement larges (machine partagée, build debug possible) : ils
/// détectent une régression d'ordre de grandeur, pas une variation fine.
final class StorePerformanceTests: XCTestCase {

    private static let channelCount = 100_000

    /// Base sur fichier et non en mémoire : c'est le coût des écritures sur disque
    /// et du journal WAL que l'on veut mesurer, pas celui de la RAM.
    private func onDiskDatabase() throws -> (UHFDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-perf-\(UUID().uuidString)/library.sqlite")
        return (try UHFDatabase.onDisk(at: url), url.deletingLastPathComponent())
    }

    func testImportsAHundredThousandChannelsWithinBudget() throws {
        let (database, directory) = try onDiskDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)

        let channels = (0..<Self.channelCount).map {
            Fixture.channel("FR | Chaîne \($0) HD", tvgID: "ch\($0).fr",
                            streamID: "\($0)", group: "Groupe \($0 % 40)", sortIndex: $0)
        }

        let started = Date()
        let session = try store.beginImport(playlistID: "p1")
        for channel in channels { try session.append(channel) }
        let report = try session.finish()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(report.added, Self.channelCount)
        print("Import : \(Self.channelCount) chaînes en \(String(format: "%.2f", elapsed)) s")
        XCTAssertLessThan(elapsed, 90, "régression d'ordre de grandeur sur l'import")

        // Recherche : la cible du plan est < 50 ms sur 150 000 chaînes.
        for query in ["chaine 4", "groupe 12", "fr"] {
            let searchStarted = Date()
            let results = try store.search(query, limit: 100)
            let searchElapsed = Date().timeIntervalSince(searchStarted)
            print("Recherche « \(query) » : \(results.count) résultats en "
                  + "\(String(format: "%.1f", searchElapsed * 1000)) ms")
            XCTAssertLessThan(searchElapsed, 1.0)
        }

        // Liste d'une catégorie : la requête que fait le défilement.
        let pageStarted = Date()
        let page = try store.channels(playlistID: "p1", group: "Groupe 7", limit: 100)
        let pageElapsed = Date().timeIntervalSince(pageStarted)
        print("Page de catégorie : \(page.count) lignes en "
              + "\(String(format: "%.1f", pageElapsed * 1000)) ms")
        XCTAssertEqual(page.count, 100)
        XCTAssertLessThan(pageElapsed, 1.0)

        let size = (try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("library.sqlite").path)[.size] as? Int) ?? 0 ?? 0
        print("Base : \(String(format: "%.1f", Double(size) / 1_048_576)) Mo")
    }

    func testResyncOfAnUnchangedPlaylistIsCheap() throws {
        let (database, directory) = try onDiskDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)

        let channels = (0..<20_000).map {
            Fixture.channel("Chaîne \($0)", tvgID: "ch\($0)", streamID: "\($0)", sortIndex: $0)
        }
        try store.merge(channels, playlistID: "p1")

        let started = Date()
        let report = try store.merge(channels, playlistID: "p1")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.updated, 20_000)
        XCTAssertEqual(report.removed, 0)
        print("Resync sans changement : 20 000 chaînes en \(String(format: "%.2f", elapsed)) s")
        XCTAssertLessThan(elapsed, 30)
    }

    func testEPGImportAndNowNextOnAWidePage() throws {
        let (database, directory) = try onDiskDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixture.playlist(in: database)

        let channelCount = 300
        let channels = (0..<channelCount).map {
            Fixture.channel("Chaîne \($0)", tvgID: "ch\($0).fr", streamID: "\($0)", sortIndex: $0)
        }
        try ChannelStore(database).merge(channels, playlistID: "p1")

        let epg = EPGStore(database)
        let base = Date()
        let started = Date()
        let session = try epg.beginImport(playlistID: "p1")
        for index in 0..<channelCount {
            try session.append(channel: EPGChannel(xmltvID: "ch\(index).fr",
                                                   displayNames: ["Chaîne \(index)"]))
        }
        // 300 chaînes x 336 créneaux d'une demi-heure = 7 jours de guide complet.
        for index in 0..<channelCount {
            for slot in 0..<336 {
                let start = base.addingTimeInterval(Double(slot) * 1800 - 86_400)
                try session.append(programme: EPGProgramme(
                    channelID: "ch\(index).fr", start: start,
                    stop: start.addingTimeInterval(1800),
                    title: "Programme \(slot)",
                    desc: "Une description de longueur réaliste pour peser autant qu'un vrai guide."))
            }
        }
        let report = try session.finish()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(report.added, channelCount * 336)
        print("EPG : \(report.added) programmes en \(String(format: "%.2f", elapsed)) s")
        XCTAssertLessThan(elapsed, 120)

        try epg.saveLinks(channels.map {
            ($0.stableKey(playlistID: "p1"), $0.tvgID!, 3)
        }, playlistID: "p1")

        // La requête du défilement : now/next pour une page de 60 chaînes visibles.
        let keys = channels.prefix(60).map { $0.stableKey(playlistID: "p1") }
        let queryStarted = Date()
        let nowNext = try epg.nowNext(channelKeys: Array(keys), playlistID: "p1")
        let queryElapsed = Date().timeIntervalSince(queryStarted)

        XCTAssertEqual(nowNext.count, 60)
        XCTAssertNotNil(nowNext[keys[0]]?.current)
        XCTAssertNotNil(nowNext[keys[0]]?.next)
        print("Now/Next sur 60 chaînes : \(String(format: "%.1f", queryElapsed * 1000)) ms")
        XCTAssertLessThan(queryElapsed, 1.0)

        let purgeStarted = Date()
        let purged = try epg.purge(before: base)
        print("Purge : \(purged) programmes en "
              + "\(String(format: "%.1f", Date().timeIntervalSince(purgeStarted) * 1000)) ms")
        XCTAssertGreaterThan(purged, 0)
    }
}
