import XCTest
import UHFCore
@testable import UHFSources

final class EPGMatcherTests: XCTestCase {

    private let guide = [
        EPGChannel(xmltvID: "TF1.fr", displayNames: ["TF1"]),
        EPGChannel(xmltvID: "M6.fr", displayNames: ["M6", "M 6"]),
        EPGChannel(xmltvID: "FranceInfo.fr", displayNames: ["France Info", "franceinfo"]),
    ]

    private func channel(_ name: String, tvgID: String? = nil, tvgName: String? = nil) -> ParsedChannel {
        ParsedChannel(name: name, url: URL(string: "http://srv/a.ts")!,
                      tvgID: tvgID, tvgName: tvgName)
    }

    func testExactIDIsHighestConfidence() throws {
        let matcher = EPGMatcher(epgChannels: guide)
        let match = try XCTUnwrap(matcher.match(channel("FR | TF1 HD", tvgID: "TF1.fr")))
        XCTAssertEqual(match.xmltvID, "TF1.fr")
        XCTAssertEqual(match.confidence, .exactID)
    }

    func testCaseDifferingIDStillMatches() throws {
        let matcher = EPGMatcher(epgChannels: guide)
        let match = try XCTUnwrap(matcher.match(channel("TF1", tvgID: "tf1.FR")))
        XCTAssertEqual(match.xmltvID, "TF1.fr")
        XCTAssertEqual(match.confidence, .normalizedID)
    }

    func testFallsBackToChannelNameWhenIDMissing() throws {
        let matcher = EPGMatcher(epgChannels: guide)
        let match = try XCTUnwrap(matcher.match(channel("FR | TF1 FHD")))
        XCTAssertEqual(match.xmltvID, "TF1.fr")
        XCTAssertEqual(match.confidence, .name)
        XCTAssertTrue(match.confidence.isTrustworthy)
    }

    func testFallsBackToTvgNameWhenDisplayNameDiffers() throws {
        let matcher = EPGMatcher(epgChannels: guide)
        let match = try XCTUnwrap(matcher.match(channel("Chaîne 1", tvgName: "M6")))
        XCTAssertEqual(match.xmltvID, "M6.fr")
    }

    func testCompactedMatchIsFlaggedWeak() throws {
        let matcher = EPGMatcher(epgChannels: guide)
        // "franceinfo" (guide, sans espace) contre "France Info" (playlist).
        let match = try XCTUnwrap(matcher.match(channel("FranceInfo")))
        XCTAssertEqual(match.xmltvID, "FranceInfo.fr")
        XCTAssertLessThanOrEqual(match.confidence, .name)
    }

    func testUnknownChannelHasNoMatch() {
        let matcher = EPGMatcher(epgChannels: guide)
        XCTAssertNil(matcher.match(channel("Chaîne inconnue du guide")))
    }

    func testWrongIDDoesNotSilentlyMatchAnotherChannel() {
        let matcher = EPGMatcher(epgChannels: guide)
        // Un tvg-id qui ne correspond à rien ne doit pas être rattrapé par le nom
        // d'une chaîne sans rapport.
        let match = matcher.match(channel("Chaîne X", tvgID: "inexistant.fr"))
        XCTAssertNil(match)
    }

    func testReportAggregatesRate() {
        let matcher = EPGMatcher(epgChannels: guide)
        let report = matcher.match(channels: [
            channel("TF1 HD", tvgID: "TF1.fr"),
            channel("M6"),
            channel("Chaîne inconnue"),
            channel("Autre inconnue"),
        ])
        XCTAssertEqual(report.total, 4)
        XCTAssertEqual(report.matchedCount, 2)
        XCTAssertEqual(report.rate, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.countsByConfidence[.exactID], 1)
        XCTAssertEqual(report.countsByConfidence[.name], 1)
        XCTAssertEqual(report.unmatched.count, 2)
    }

    func testAmbiguityResolutionIsDeterministic() {
        let ambiguous = [
            EPGChannel(xmltvID: "A", displayNames: ["Sport"]),
            EPGChannel(xmltvID: "B", displayNames: ["Sport"]),
        ]
        let first = EPGMatcher(epgChannels: ambiguous).match(channel("Sport"))
        let second = EPGMatcher(epgChannels: ambiguous).match(channel("Sport"))
        XCTAssertEqual(first?.xmltvID, "A", "la première chaîne déclarée doit gagner")
        XCTAssertEqual(first, second)
    }
}
