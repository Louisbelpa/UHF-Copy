import XCTest
import UHFCore
@testable import UHFSources

final class XMLTVDateTests: XCTestCase {

    func testFullFormatWithOffset() throws {
        let date = try XCTUnwrap(XMLTVDate.parse("20240115203000 +0100"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_705_347_000, accuracy: 1)
    }

    func testNegativeOffset() throws {
        let date = try XCTUnwrap(XMLTVDate.parse("20240115203000 -0530"))
        let reference = try XCTUnwrap(XMLTVDate.parse("20240115203000 +0000"))
        XCTAssertEqual(date.timeIntervalSince(reference), 5.5 * 3600, accuracy: 1)
    }

    func testWithoutOffsetAssumesUTC() throws {
        let implicit = try XCTUnwrap(XMLTVDate.parse("20240115203000"))
        let explicit = try XCTUnwrap(XMLTVDate.parse("20240115203000 +0000"))
        XCTAssertEqual(implicit, explicit)
    }

    func testTruncatedForms() throws {
        // Minutes seules, puis date seule : acceptées, complétées par des zéros.
        let minutes = try XCTUnwrap(XMLTVDate.parse("202401152030"))
        XCTAssertEqual(minutes, try XCTUnwrap(XMLTVDate.parse("20240115203000 +0000")))

        let dayOnly = try XCTUnwrap(XMLTVDate.parse("20240115"))
        XCTAssertEqual(dayOnly, try XCTUnwrap(XMLTVDate.parse("20240115000000 +0000")))
    }

    func testOffsetWithoutSpaceAndZSuffix() throws {
        XCTAssertEqual(try XCTUnwrap(XMLTVDate.parse("20240115203000+0100")),
                       try XCTUnwrap(XMLTVDate.parse("20240115203000 +0100")))
        XCTAssertEqual(try XCTUnwrap(XMLTVDate.parse("20240115203000 Z")),
                       try XCTUnwrap(XMLTVDate.parse("20240115203000 +0000")))
    }

    func testRejectsGarbage() {
        XCTAssertNil(XMLTVDate.parse(""))
        XCTAssertNil(XMLTVDate.parse("bientôt"))
        XCTAssertNil(XMLTVDate.parse("2024"))
    }

    func testMatchesDateFormatterOnRandomSamples() throws {
        // Le parseur manuel doit être rigoureusement équivalent à la référence lente.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"

        for _ in 0..<200 {
            let seconds = Double.random(in: 1_500_000_000...1_900_000_000).rounded()
            let reference = Date(timeIntervalSince1970: seconds)
            let text = formatter.string(from: reference)
            let parsed = try XCTUnwrap(XMLTVDate.parse(text), "échec sur \(text)")
            XCTAssertEqual(parsed.timeIntervalSince1970, seconds, accuracy: 1, "sur \(text)")
        }
    }
}

final class XMLTVParserTests: XCTestCase {

    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv generator-info-name="test">
      <channel id="TF1.fr">
        <display-name lang="fr">TF1</display-name>
        <display-name>TF1 HD</display-name>
        <icon src="http://srv/tf1.png"/>
      </channel>
      <channel id="M6.fr">
        <display-name>M6</display-name>
      </channel>
      <programme start="20240115200000 +0100" stop="20240115204500 +0100" channel="TF1.fr">
        <title lang="en">The 8 O'Clock News</title>
        <title lang="fr">Le 20 heures</title>
        <sub-title lang="fr">Édition du soir</sub-title>
        <desc lang="fr">Toute l'actualité.</desc>
        <category lang="fr">Information</category>
        <category lang="fr">Journal</category>
        <icon src="http://srv/jt.png"/>
        <episode-num system="xmltv_ns">0.2.0/1</episode-num>
      </programme>
      <programme start="20240115204500 +0100" stop="20240115230000 +0100" channel="TF1.fr">
        <title>Film du soir</title>
        <desc><![CDATA[Un <résumé> avec des entités & du CDATA.]]></desc>
      </programme>
    </tv>
    """

    private func run(_ xml: String, options: XMLTVParser.Options = .init())
        throws -> (channels: [EPGChannel], programmes: [EPGProgramme], summary: XMLTVParser.Summary) {
        var channels: [EPGChannel] = []
        var programmes: [EPGProgramme] = []
        let parser = XMLTVParser(options: options,
                                 onChannel: { channels.append($0) },
                                 onProgramme: { programmes.append($0) })
        let summary = try parser.parse(data: Data(xml.utf8))
        return (channels, programmes, summary)
    }

    func testParsesChannelsAndProgrammes() throws {
        let result = try run(sample)
        XCTAssertEqual(result.summary.channelCount, 2)
        XCTAssertEqual(result.summary.programmeCount, 2)

        let tf1 = try XCTUnwrap(result.channels.first)
        XCTAssertEqual(tf1.xmltvID, "TF1.fr")
        XCTAssertEqual(tf1.displayNames, ["TF1", "TF1 HD"])
        XCTAssertEqual(tf1.iconURL?.absoluteString, "http://srv/tf1.png")

        let news = try XCTUnwrap(result.programmes.first)
        XCTAssertEqual(news.channelID, "TF1.fr")
        XCTAssertEqual(news.subtitle, "Édition du soir")
        XCTAssertEqual(news.categories, ["Information", "Journal"])
        XCTAssertEqual(news.duration, 2700)
        XCTAssertEqual(news.episodeNumber, "0.2.0/1")
    }

    func testPrefersRequestedLanguage() throws {
        let french = try run(sample, options: .init(preferredLanguages: ["fr"]))
        XCTAssertEqual(french.programmes[0].title, "Le 20 heures")

        let english = try run(sample, options: .init(preferredLanguages: ["en"]))
        XCTAssertEqual(english.programmes[0].title, "The 8 O'Clock News")

        // Langue absente du fichier : on retombe sur le premier titre disponible.
        let german = try run(sample, options: .init(preferredLanguages: ["de"]))
        XCTAssertEqual(german.programmes[0].title, "The 8 O'Clock News")
    }

    func testHandlesCDATAAndEntities() throws {
        let result = try run(sample)
        XCTAssertEqual(result.programmes[1].desc, "Un <résumé> avec des entités & du CDATA.")
    }

    func testWindowFiltersOutOfRangeProgrammes() throws {
        let start = try XCTUnwrap(XMLTVDate.parse("20240115210000 +0100"))
        let end = try XCTUnwrap(XMLTVDate.parse("20240116000000 +0100"))
        let result = try run(sample, options: .init(window: start...end))

        XCTAssertEqual(result.summary.programmeCount, 1, "seul le film chevauche la fenêtre")
        XCTAssertEqual(result.summary.skippedCount, 1)
        XCTAssertEqual(result.programmes[0].title, "Film du soir")
    }

    func testMissingStopGetsDefaultDuration() throws {
        let xml = """
        <tv><programme start="20240115200000 +0100" channel="A"><title>X</title></programme></tv>
        """
        let result = try run(xml)
        XCTAssertEqual(result.programmes[0].duration, 3600)
    }

    func testProgrammeWithUnparsableDateIsSkippedNotFatal() throws {
        let xml = """
        <tv>
          <programme start="pas une date" channel="A"><title>Cassé</title></programme>
          <programme start="20240115200000 +0100" stop="20240115210000 +0100" channel="A">
            <title>Valide</title>
          </programme>
        </tv>
        """
        let result = try run(xml)
        XCTAssertEqual(result.summary.programmeCount, 1)
        XCTAssertEqual(result.summary.skippedCount, 1)
        XCTAssertEqual(result.programmes[0].title, "Valide")
    }

    func testInvertedTimesAreRejected() throws {
        let xml = """
        <tv><programme start="20240115210000 +0100" stop="20240115200000 +0100" channel="A">
        <title>À l'envers</title></programme></tv>
        """
        let result = try run(xml)
        XCTAssertEqual(result.summary.programmeCount, 0)
        XCTAssertEqual(result.summary.skippedCount, 1)
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try run("<tv><channel id=\"A\"><display-name>A</tv>"))
    }

    func testCancellationStopsParsing() throws {
        var xml = "<tv>"
        for index in 0..<2_000 {
            xml += """
            <programme start="20240115200000 +0000" stop="20240115210000 +0000" channel="C\(index)">
            <title>P\(index)</title></programme>
            """
        }
        xml += "</tv>"

        var count = 0
        let parser = XMLTVParser(options: .init(),
                                 isCancelled: { count >= 50 },
                                 onChannel: { _ in },
                                 onProgramme: { _ in count += 1 })
        XCTAssertThrowsError(try parser.parse(data: Data(xml.utf8))) { error in
            guard case XMLTVParser.Failure.cancelled = error else {
                return XCTFail("attendu .cancelled, reçu \(error)")
            }
        }
        XCTAssertLessThan(count, 200)
    }

    // MARK: - Gzip

    func testParsesGzippedFileTransparently() throws {
        let directory = FileManager.default.temporaryDirectory
        let plain = directory.appendingPathComponent("uhf-\(UUID().uuidString).xml")
        let gzipped = directory.appendingPathComponent("uhf-\(UUID().uuidString).xml.gz")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: gzipped)
        }

        // Fichier volumineux, pour exercer le découpage en blocs de l'inflate.
        var xml = "<tv>"
        for index in 0..<20_000 {
            xml += """
            <programme start="20240115200000 +0000" stop="20240115210000 +0000" channel="C\(index % 50)">
            <title>Programme numéro \(index)</title><desc>Description assez longue pour peser.</desc>
            </programme>
            """
        }
        xml += "</tv>"
        try xml.write(to: plain, atomically: true, encoding: .utf8)

        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gzip.arguments = ["sh", "-c", "gzip -c '\(plain.path)' > '\(gzipped.path)'"]
        try gzip.run()
        gzip.waitUntilExit()
        try XCTSkipUnless(gzip.terminationStatus == 0, "gzip indisponible")

        XCTAssertTrue(Gunzip.isGzip(fileAt: gzipped))
        XCTAssertFalse(Gunzip.isGzip(fileAt: plain))

        var count = 0
        let parser = XMLTVParser(onChannel: { _ in }, onProgramme: { _ in count += 1 })
        let summary = try parser.parse(fileAt: gzipped)

        XCTAssertEqual(count, 20_000)
        XCTAssertEqual(summary.programmeCount, 20_000)

        // Le même fichier non compressé doit donner exactement le même résultat.
        var plainCount = 0
        let plainParser = XMLTVParser(onChannel: { _ in }, onProgramme: { _ in plainCount += 1 })
        _ = try plainParser.parse(fileAt: plain)
        XCTAssertEqual(plainCount, count)
    }

    func testDecompressPassesThroughUncompressedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
        let source = directory.appendingPathComponent("uhf-\(UUID().uuidString).xml")
        let destination = directory.appendingPathComponent("uhf-\(UUID().uuidString).out")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try "<tv></tv>".write(to: source, atomically: true, encoding: .utf8)
        try Gunzip.decompress(from: source, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "<tv></tv>")
    }
}
