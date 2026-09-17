import XCTest
import UHFCore
@testable import UHFSources

final class M3UParserTests: XCTestCase {

    // MARK: - Cas nominal

    func testParsesStandardEntry() throws {
        let text = """
        #EXTM3U url-tvg="http://srv/xmltv.php?username=u&password=p"
        #EXTINF:-1 tvg-id="TF1.fr" tvg-name="TF1" tvg-logo="http://srv/tf1.png" group-title="FR | Généralistes",TF1 HD
        http://srv/live/u/p/1234.ts
        """
        let output = M3UParser.parse(text: text)

        XCTAssertEqual(output.header.epgURLs.count, 1)
        XCTAssertEqual(output.channels.count, 1)

        let channel = try XCTUnwrap(output.channels.first)
        XCTAssertEqual(channel.name, "TF1 HD")
        XCTAssertEqual(channel.tvgID, "TF1.fr")
        XCTAssertEqual(channel.tvgName, "TF1")
        XCTAssertEqual(channel.groupTitle, "FR | Généralistes")
        XCTAssertEqual(channel.logoURL?.absoluteString, "http://srv/tf1.png")
        XCTAssertEqual(channel.url.absoluteString, "http://srv/live/u/p/1234.ts")
        XCTAssertEqual(channel.streamID, "1234", "l'ID Xtream doit être récupéré depuis l'URL")
    }

    // MARK: - Pièges de syntaxe

    func testTitleMayContainCommas() throws {
        let text = """
        #EXTINF:-1 tvg-id="x",Le Journal, en direct, 20h
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.name, "Le Journal, en direct, 20h")
    }

    func testQuotedAttributeValueMayContainCommasAndEquals() throws {
        let text = """
        #EXTINF:-1 tvg-name="Foo, Bar = Baz" group-title="A,B",Titre
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.tvgName, "Foo, Bar = Baz")
        XCTAssertEqual(channel.groupTitle, "A,B")
        XCTAssertEqual(channel.name, "Titre")
    }

    func testSingleQuotedAndUnquotedValues() throws {
        let text = """
        #EXTINF:-1 tvg-id='TF1.fr' tvg-logo=http://srv/logo.png,TF1
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.tvgID, "TF1.fr")
        XCTAssertEqual(channel.logoURL?.absoluteString, "http://srv/logo.png")
    }

    func testEntryWithoutCommaFallsBackToTvgName() throws {
        let text = """
        #EXTINF:-1 tvg-name="Fallback"
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.name, "Fallback")
    }

    func testEntryWithNoAttributesAtAll() throws {
        let text = """
        #EXTINF:-1,Chaîne nue
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.name, "Chaîne nue")
        XCTAssertNil(channel.tvgID)
    }

    func testBareURLsWithoutExtinfAreAccepted() {
        let text = """
        #EXTM3U
        http://srv/a.ts
        http://srv/b.ts
        """
        XCTAssertEqual(M3UParser.parse(text: text).channels.count, 2)
    }

    func testCRLFAndBlankLinesAndUnknownDirectives() {
        let text = "#EXTM3U\r\n\r\n#KODIPROP:inputstream.adaptive.license_type=widevine\r\n"
            + "#EXTINF:-1,A\r\nhttp://srv/a.ts\r\n\r\n#EXTINF:-1,B\r\nhttp://srv/b.ts\r\n"
        let output = M3UParser.parse(text: text)
        XCTAssertEqual(output.channels.map(\.name), ["A", "B"])
    }

    func testMalformedEntryDoesNotAbortTheImport() {
        // Une URL vide au milieu ne doit pas faire perdre les 149 999 autres chaînes.
        let text = """
        #EXTINF:-1,A
        http://srv/a.ts
        #EXTINF:-1,Cassée
        |User-Agent=x
        #EXTINF:-1,B
        http://srv/b.ts
        """
        let output = M3UParser.parse(text: text)
        XCTAssertEqual(output.channels.map(\.name), ["A", "B"])
        XCTAssertEqual(output.skipped.count, 1)
    }

    // MARK: - Groupes, en-têtes, catch-up

    func testExtgrpUsedWhenGroupTitleAbsent() throws {
        let text = """
        #EXTINF:-1,A
        #EXTGRP:Sport
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.groupTitle, "Sport")
    }

    func testGroupTitleWinsOverExtgrp() throws {
        let text = """
        #EXTINF:-1 group-title="Cinéma",A
        #EXTGRP:Sport
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.groupTitle, "Cinéma")
    }

    func testVLCOptionsBecomeHTTPHeaders() throws {
        let text = """
        #EXTINF:-1,A
        #EXTVLCOPT:http-user-agent=VLC/3.0.20
        #EXTVLCOPT:http-referrer=http://srv/
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.httpHeaders["User-Agent"], "VLC/3.0.20")
        XCTAssertEqual(channel.httpHeaders["Referer"], "http://srv/")
    }

    func testExtHTTPJSONHeaders() throws {
        let text = """
        #EXTINF:-1,A
        #EXTHTTP:{"User-Agent":"Custom/1.0"}
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.httpHeaders["User-Agent"], "Custom/1.0")
    }

    func testInlinePipeHeadersOnURL() throws {
        let text = """
        #EXTINF:-1,A
        http://srv/a.ts|User-Agent=Mozilla&Referer=http%3A%2F%2Fsrv%2F
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.url.absoluteString, "http://srv/a.ts")
        XCTAssertEqual(channel.httpHeaders["User-Agent"], "Mozilla")
        XCTAssertEqual(channel.httpHeaders["Referer"], "http://srv/")
    }

    func testInlineHeadersOverrideVLCOptions() throws {
        let text = """
        #EXTINF:-1,A
        #EXTVLCOPT:http-user-agent=VLC/3.0
        http://srv/a.ts|User-Agent=Mozilla
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.httpHeaders["User-Agent"], "Mozilla")
    }

    func testCatchupAttributes() throws {
        let text = """
        #EXTINF:-1 catchup="shift" catchup-days="7" tvg-shift="-1.5",A
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.catchup, .shift)
        XCTAssertEqual(channel.catchupDays, 7)
        XCTAssertEqual(channel.tvgShift, -5400, "tvg-shift est en heures, stocké en secondes")
        XCTAssertTrue(channel.supportsCatchup)
    }

    func testCatchupSourceImpliesAppendMode() throws {
        let text = """
        #EXTINF:-1 catchup-source="http://srv/a.ts?utc={utc}" catchup-days="3",A
        http://srv/a.ts
        """
        let channel = try XCTUnwrap(M3UParser.parse(text: text).channels.first)
        XCTAssertEqual(channel.catchup, .append)
    }

    func testSortIndexIsMonotonic() {
        let text = """
        #EXTINF:-1,A
        http://srv/a.ts
        #EXTINF:-1,B
        http://srv/b.ts
        #EXTINF:-1,C
        http://srv/c.ts
        """
        XCTAssertEqual(M3UParser.parse(text: text).channels.map(\.sortIndex), [0, 1, 2])
    }

    func testMultipleEPGURLs() {
        let text = #"#EXTM3U x-tvg-url="http://a/epg.xml,http://b/epg.xml.gz""#
        XCTAssertEqual(M3UParser.parse(text: text).header.epgURLs.count, 2)
    }

    // MARK: - Lecture en flux

    func testStreamingFileParseMatchesInMemoryParse() throws {
        var text = "#EXTM3U url-tvg=\"http://srv/epg.xml\"\n"
        for index in 0..<5_000 {
            text += "#EXTINF:-1 tvg-id=\"c\(index)\" group-title=\"G\(index % 20)\",Chaîne \(index)\n"
            text += "http://srv/live/u/p/\(index).ts\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-test-\(UUID().uuidString).m3u")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var streamed: [ParsedChannel] = []
        let result = try M3UParser.parse(fileAt: url) { streamed.append($0) }

        XCTAssertEqual(result.count, 5_000)
        XCTAssertEqual(result.header.epgURLs.first?.absoluteString, "http://srv/epg.xml")
        XCTAssertEqual(streamed.map(\.name), M3UParser.parse(text: text).channels.map(\.name))
        XCTAssertEqual(streamed.last?.streamID, "4999")
    }

    func testStreamingHandlesBOMAndCRLF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-bom-\(UUID().uuidString).m3u")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("#EXTM3U\r\n#EXTINF:-1,Avec BOM\r\nhttp://srv/a.ts\r\n".data(using: .utf8)!)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var names: [String] = []
        try M3UParser.parse(fileAt: url) { names.append($0.name) }
        XCTAssertEqual(names, ["Avec BOM"])
    }

    func testCancellationStopsEarly() throws {
        var text = ""
        for index in 0..<1_000 {
            text += "#EXTINF:-1,C\(index)\nhttp://srv/\(index).ts\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-cancel-\(UUID().uuidString).m3u")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var count = 0
        let result = try M3UParser.parse(fileAt: url, isCancelled: { count >= 10 }) { _ in count += 1 }
        XCTAssertLessThan(result.count, 20, "l'annulation doit interrompre l'import rapidement")
    }
}
