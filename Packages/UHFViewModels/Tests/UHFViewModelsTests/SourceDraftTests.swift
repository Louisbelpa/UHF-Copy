import XCTest
import UHFCore
@testable import UHFViewModels

final class SourceDraftTests: XCTestCase {

    func testDetectsXtreamFromAPastedGetPhpURL() throws {
        let draft = SourceDraft(rawURL: "http://srv.tv:8080/get.php?username=bob&password=s3cret&type=m3u_plus")
        guard case .xtream(let baseURL, let username, let password) = draft.detected else {
            return XCTFail("attendu .xtream, reçu \(draft.detected)")
        }
        XCTAssertEqual(baseURL.absoluteString, "http://srv.tv:8080")
        XCTAssertEqual(username, "bob")
        XCTAssertEqual(password, "s3cret")
    }

    func testPrefersXtreamOverM3UWhenCredentialsArePresent() {
        // L'API Xtream donne films, séries et EPG court ; le M3U qu'elle sert n'est
        // qu'un sous-ensemble. À URL identique, c'est donc Xtream qu'il faut choisir.
        let draft = SourceDraft(rawURL: "http://srv/get.php?username=u&password=p")
        if case .m3u = draft.detected { XCTFail("ne doit pas retomber sur M3U") }
    }

    func testDetectsPlainM3U() throws {
        let draft = SourceDraft(rawURL: "https://exemple.fr/ma-liste.m3u")
        guard case .m3u(let url) = draft.detected else {
            return XCTFail("attendu .m3u")
        }
        XCTAssertEqual(url.absoluteString, "https://exemple.fr/ma-liste.m3u")
    }

    func testAddsMissingScheme() throws {
        let draft = SourceDraft(rawURL: "exemple.fr/liste.m3u")
        guard case .m3u(let url) = draft.detected else { return XCTFail("attendu .m3u") }
        XCTAssertEqual(url.scheme, "http")
    }

    func testTrimsWhitespaceFromPastedText() throws {
        // Ce que l'utilisateur colle depuis un message contient presque toujours
        // un espace ou un retour à la ligne.
        let draft = SourceDraft(rawURL: "  http://srv/get.php?username=u&password=p\n")
        guard case .xtream = draft.detected else { return XCTFail("attendu .xtream") }
    }

    func testRejectsEmptyAndNonsense() {
        XCTAssertFalse(SourceDraft(rawURL: "").isValid)
        XCTAssertFalse(SourceDraft(rawURL: "   ").isValid)
        XCTAssertFalse(SourceDraft(rawURL: "pas une url du tout !!").isValid,
                       "une saisie comportant des espaces ne peut pas être une URL")
    }

    func testAcceptsABareHostname() {
        // Un nom d'hôte seul reste plausible : serveur local, machine sur le réseau.
        XCTAssertTrue(SourceDraft(rawURL: "mon-nas.local/liste.m3u").isValid)
    }

    func testSuggestedNameFallsBackToHost() {
        XCTAssertEqual(SourceDraft(rawURL: "http://mon-serveur.tv/liste.m3u").suggestedName,
                       "mon-serveur.tv")
        XCTAssertEqual(SourceDraft(name: "  Chez moi  ",
                                   rawURL: "http://srv/liste.m3u").suggestedName, "Chez moi")
    }

    func testCredentialsAreHandedBackSeparatelyForTheKeychain() throws {
        let draft = SourceDraft(rawURL: "http://srv/get.php?username=u&password=p")
        let made = try XCTUnwrap(draft.makeRecord(id: "abc"))

        XCTAssertEqual(made.playlist.kind, PlaylistKind.xtream.rawValue)
        XCTAssertEqual(made.credentials?.username, "u")
        XCTAssertEqual(made.credentials?.password, "p")
        XCTAssertEqual(made.playlist.credentialsRef, "abc")

        // Le mot de passe ne doit apparaître nulle part dans ce qui part en base.
        let encoded = try XCTUnwrap(String(data: try JSONEncoder().encode(made.playlist),
                                           encoding: .utf8))
        XCTAssertFalse(encoded.contains("s3cret"))
        XCTAssertFalse(encoded.contains("\"password\""))
    }

    func testM3URecordCarriesNoCredentials() throws {
        let made = try XCTUnwrap(SourceDraft(rawURL: "http://srv/liste.m3u").makeRecord())
        XCTAssertNil(made.credentials)
        XCTAssertEqual(made.playlist.kind, PlaylistKind.m3u.rawValue)
    }
}
