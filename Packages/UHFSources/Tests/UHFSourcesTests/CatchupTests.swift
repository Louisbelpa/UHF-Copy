import XCTest
import UHFCore
@testable import UHFSources

final class CatchupURLBuilderTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_705_347_000)   // 2024-01-15 19:30 UTC
    private let duration: TimeInterval = 2700

    private func channel(catchup: CatchupMode?,
                         source: String? = nil,
                         url: String = "http://srv/live/u/p/1234.ts") -> ParsedChannel {
        ParsedChannel(name: "TF1", url: URL(string: url)!,
                      catchup: catchup, catchupDays: 7, catchupSource: source)
    }

    func testReturnsNilWhenChannelHasNoCatchup() {
        XCTAssertNil(CatchupURLBuilder.url(for: channel(catchup: nil),
                                           start: start, duration: duration))
    }

    func testDefaultModeAppendsUTCParameters() throws {
        let url = try XCTUnwrap(CatchupURLBuilder.url(for: channel(catchup: .default),
                                                      start: start, duration: duration))
        XCTAssertTrue(url.absoluteString.contains("utc=1705347000"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("lutc="))
    }

    func testDefaultModePreservesExistingQuery() throws {
        let channel = channel(catchup: .default, url: "http://srv/live.m3u8?token=abc")
        let url = try XCTUnwrap(CatchupURLBuilder.url(for: channel, start: start, duration: duration))
        XCTAssertTrue(url.absoluteString.contains("token=abc"))
        XCTAssertTrue(url.absoluteString.contains("utc=1705347000"))
    }

    func testAppendModeConcatenatesSuffix() throws {
        let channel = channel(catchup: .append, source: "?utc={utc}&duration={duration}")
        let url = try XCTUnwrap(CatchupURLBuilder.url(for: channel, start: start, duration: duration))
        XCTAssertEqual(url.absoluteString,
                       "http://srv/live/u/p/1234.ts?utc=1705347000&duration=2700")
    }

    func testAppendModeUsesAmpersandWhenURLAlreadyHasQuery() throws {
        let channel = channel(catchup: .append, source: "utc={utc}",
                              url: "http://srv/live.m3u8?token=abc")
        let url = try XCTUnwrap(CatchupURLBuilder.url(for: channel, start: start, duration: duration))
        XCTAssertEqual(url.absoluteString, "http://srv/live.m3u8?token=abc&utc=1705347000")
    }

    func testExplicitTemplateWinsOverDefaultBehaviour() throws {
        let channel = channel(catchup: .shift,
                              source: "http://srv/archive/${start}-${end}.m3u8")
        let url = try XCTUnwrap(CatchupURLBuilder.url(for: channel, start: start, duration: duration))
        XCTAssertEqual(url.absoluteString, "http://srv/archive/1705347000-1705349700.m3u8")
    }

    func testFlussonicConventionWithoutTemplate() throws {
        let channel = channel(catchup: .flussonic, url: "http://srv/ch1/index.m3u8")
        let url = try XCTUnwrap(CatchupURLBuilder.url(for: channel, start: start, duration: duration))
        XCTAssertEqual(url.absoluteString, "http://srv/ch1/index-1705347000-2700.m3u8")
    }

    func testBothTokenSpellingsAreSupported() {
        let braces = CatchupURLBuilder.substitute("a={utc}&b={duration}",
                                                  start: start,
                                                  end: start.addingTimeInterval(duration),
                                                  duration: duration)
        let dollars = CatchupURLBuilder.substitute("a=${utc}&b=${duration}",
                                                   start: start,
                                                   end: start.addingTimeInterval(duration),
                                                   duration: duration)
        XCTAssertEqual(braces, "a=1705347000&b=2700")
        XCTAssertEqual(dollars, braces)
    }

    func testDateComponentTokens() {
        let result = CatchupURLBuilder.substitute("{Y}/{m}/{d} {H}:{M}:{S}",
                                                  start: start,
                                                  end: start.addingTimeInterval(duration),
                                                  duration: duration)
        XCTAssertEqual(result, "2024/01/15 19:30:00")
    }

    func testXtreamTimestampFormat() {
        XCTAssertEqual(CatchupURLBuilder.xtreamTimestamp(start), "2024-01-15:19-30")
    }

    func testXtreamModeIsBuiltByTheClientNotHere() {
        // Le constructeur générique n'a pas les identifiants : il doit rendre la main.
        XCTAssertNil(CatchupURLBuilder.url(for: channel(catchup: .xtream),
                                           start: start, duration: duration))
    }

    func testCatchupModeParsingAcceptsKnownSpellings() {
        XCTAssertEqual(CatchupMode(rawAttribute: "default"), .default)
        XCTAssertEqual(CatchupMode(rawAttribute: "1"), .default)
        XCTAssertEqual(CatchupMode(rawAttribute: "timeshift"), .shift)
        XCTAssertEqual(CatchupMode(rawAttribute: "Flussonic"), .flussonic)
        XCTAssertEqual(CatchupMode(rawAttribute: " append "), .append)
        XCTAssertNil(CatchupMode(rawAttribute: "n'importe quoi"))
    }
}
