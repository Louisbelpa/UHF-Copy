import XCTest
import UHFCore
@testable import UHFSources

/// Vérifie les cibles annoncées dans `docs/PLAN.md` §6.
///
/// Les seuils sont volontairement larges (machine de CI partagée, build debug) : ils
/// servent à détecter une régression d'ordre de grandeur, pas à mesurer finement.
/// Une exécution en `release` sur un appareil réel est plus rapide d'un facteur 3 à 10.
final class PerformanceTests: XCTestCase {

    func testParses100kChannelPlaylistWithinBudget() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-perf-\(UUID().uuidString).m3u")
        defer { try? FileManager.default.removeItem(at: url) }

        var text = "#EXTM3U url-tvg=\"http://srv/epg.xml.gz\"\n"
        text.reserveCapacity(20_000_000)
        for index in 0..<100_000 {
            text += """
            #EXTINF:-1 tvg-id="ch\(index).fr" tvg-name="Chaîne \(index)" \
            tvg-logo="http://srv/logos/\(index).png" group-title="FR | Groupe \(index % 40)",\
            FR | Chaîne \(index) HD
            http://srv/live/u/p/\(index).ts
            """ + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)

        let sizeMB = Double(try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) / 1_048_576

        var count = 0
        let started = Date()
        let result = try M3UParser.parse(fileAt: url) { _ in count += 1 }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(count, 100_000)
        XCTAssertEqual(result.count, 100_000)
        XCTAssertTrue(result.skipped.isEmpty)
        print("M3U : \(count) chaînes, \(String(format: "%.1f", sizeMB)) Mo en "
              + "\(String(format: "%.2f", elapsed)) s")
        XCTAssertLessThan(elapsed, 20, "régression d'ordre de grandeur sur le parsing M3U")
    }

    func testStableKeyGenerationIsNotABottleneck() {
        let names = (0..<20_000).map { "FR | Chaîne \($0) HD ᴴᴰ" }
        let started = Date()
        var keys = Set<StableKey>()
        for name in names {
            keys.insert(.channel(playlistID: "p1", tvgID: nil, name: name))
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(keys.count, 20_000, "aucune collision attendue")
        print("Clés : 20 000 en \(String(format: "%.2f", elapsed)) s (normalisation incluse)")
        XCTAssertLessThan(elapsed, 20)
    }

    func testXMLTVImportWithinBudget() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-perf-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
        xml.reserveCapacity(60_000_000)
        for channel in 0..<200 {
            xml += "<channel id=\"ch\(channel).fr\"><display-name>Chaîne \(channel)</display-name></channel>\n"
        }
        // 200 chaînes x 500 programmes = 100 000 programmes.
        for channel in 0..<200 {
            for slot in 0..<500 {
                let start = 1_705_000_000 + slot * 1800
                xml += """
                <programme start="\(timestamp(start))" stop="\(timestamp(start + 1800))" channel="ch\(channel).fr">\
                <title lang="fr">Programme \(slot)</title>\
                <desc lang="fr">Une description de longueur réaliste pour peser autant qu'un vrai fichier EPG.</desc>\
                <category lang="fr">Divertissement</category></programme>

                """
            }
        }
        xml += "</tv>\n"
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let sizeMB = Double(try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) / 1_048_576

        var programmes = 0
        var channels = 0
        let parser = XMLTVParser(options: .init(preferredLanguages: ["fr"]),
                                 onChannel: { _ in channels += 1 },
                                 onProgramme: { _ in programmes += 1 })
        let started = Date()
        let summary = try parser.parse(fileAt: url)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(channels, 200)
        XCTAssertEqual(programmes, 100_000)
        XCTAssertEqual(summary.programmeCount, 100_000)
        print("XMLTV : \(programmes) programmes, \(String(format: "%.1f", sizeMB)) Mo en "
              + "\(String(format: "%.2f", elapsed)) s")
        XCTAssertLessThan(elapsed, 60, "régression d'ordre de grandeur sur l'import EPG")
    }

    private func timestamp(_ epoch: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(epoch))) + " +0000"
    }
}
