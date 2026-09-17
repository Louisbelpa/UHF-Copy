import XCTest
@testable import UHFCore

final class NormalizationTests: XCTestCase {

    func testStripsCountryPrefixes() {
        XCTAssertEqual("FR: TF1".normalizedForMatching, "tf1")
        XCTAssertEqual("FR | TF1".normalizedForMatching, "tf1")
        XCTAssertEqual("|FR| TF1".normalizedForMatching, "tf1")
        XCTAssertEqual("[FR] TF1".normalizedForMatching, "tf1")
        XCTAssertEqual("FR - TF1".normalizedForMatching, "tf1")
    }

    func testStripsQualityMarkers() {
        XCTAssertEqual("TF1 HD".normalizedForMatching, "tf1")
        XCTAssertEqual("TF1 FHD".normalizedForMatching, "tf1")
        XCTAssertEqual("TF1 4K".normalizedForMatching, "tf1")
        XCTAssertEqual("TF1 1080p".normalizedForMatching, "tf1")
        XCTAssertEqual("TF1 H265".normalizedForMatching, "tf1")
        XCTAssertEqual("TF1 UHD RAW".normalizedForMatching, "tf1")
    }

    func testStripsDiacriticsAndDecorations() {
        XCTAssertEqual("Canal+ Séries ᴴᴰ".normalizedForMatching, "canal series")
        XCTAssertEqual("RTBF La Une".normalizedForMatching, "rtbf la une")
    }

    func testDifferentSourcesConvergeOnSameKey() {
        let fromPlaylist = "FR | TF1 FHD ᴴᴰ".normalizedForMatching
        let fromEPG = "TF1".normalizedForMatching
        XCTAssertEqual(fromPlaylist, fromEPG)
    }

    func testDoesNotEatLegitimateWordsContainingQualityTokens() {
        // "Sd" dans "Sderot", "hd" dans "Ahdaf" : la borne de mot doit protéger.
        XCTAssertEqual("Sderot TV".normalizedForMatching, "sderot tv")
        XCTAssertEqual("Ahdaf Sport".normalizedForMatching, "ahdaf sport")
    }

    func testChannelNumbersSurvive() {
        XCTAssertEqual("France 2 HD".normalizedForMatching, "france 2")
        XCTAssertEqual("M6 HD".normalizedForMatching, "m6")
    }
}

final class StableKeyTests: XCTestCase {

    func testIsDeterministicAcrossCalls() {
        let a = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        let b = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        XCTAssertEqual(a, b)
    }

    func testIsStableWhenProviderRenamesChannelButKeepsTvgID() {
        let before = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "FR | TF1 HD")
        let after = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "FR: TF1 FHD")
        XCTAssertEqual(before, after, "un renommage côté fournisseur ne doit pas casser les favoris")
    }

    func testFallsBackToNormalizedNameWhenTvgIDMissing() {
        let before = StableKey.channel(playlistID: "p1", tvgID: nil, name: "FR | TF1 HD")
        let after = StableKey.channel(playlistID: "p1", tvgID: "", name: "TF1")
        XCTAssertEqual(before, after)
    }

    func testDiffersAcrossPlaylists() {
        let p1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        let p2 = StableKey.channel(playlistID: "p2", tvgID: "TF1.fr", name: "TF1")
        XCTAssertNotEqual(p1, p2)
    }

    func testDiffersAcrossChannels() {
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        let m6 = StableKey.channel(playlistID: "p1", tvgID: "M6.fr", name: "M6")
        XCTAssertNotEqual(tf1, m6)
    }

    func testKnownVectorPinsTheHashFunction() {
        // Fige FNV-1a : si ce test casse, toutes les clés déjà écrites chez les
        // utilisateurs deviennent orphelines. Une migration est alors obligatoire.
        XCTAssertEqual(StableKey.fnv1a(""), "cbf29ce484222325")
        XCTAssertEqual(StableKey.fnv1a("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(StableKey.fnv1a("foobar"), "85944171f73967e8")
    }

    func testEpisodeKeyDerivesFromSeries() {
        let series = StableKey.series(playlistID: "p1", title: "The Wire")
        let e1 = StableKey.episode(seriesKey: series, season: 1, number: 1)
        let e2 = StableKey.episode(seriesKey: series, season: 1, number: 2)
        XCTAssertNotEqual(e1, e2)
        XCTAssertEqual(e1, StableKey.episode(seriesKey: series, season: 1, number: 1))
    }
}

final class AdultDetectionTests: XCTestCase {
    func testFlagsAdultCategories() throws {
        let url = try XCTUnwrap(URL(string: "http://x/y.ts"))
        let adult = ParsedChannel(name: "Some Channel", url: url, groupTitle: "FR | XXX")
        XCTAssertTrue(adult.isLikelyAdult)

        let normal = ParsedChannel(name: "TF1", url: url, groupTitle: "FR | Généralistes")
        XCTAssertFalse(normal.isLikelyAdult)
    }
}
