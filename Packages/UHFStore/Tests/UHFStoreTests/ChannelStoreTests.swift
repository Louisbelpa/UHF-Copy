import XCTest
import UHFCore
@testable import UHFStore

final class ChannelImportTests: XCTestCase {

    func testFreshImportCountsEverythingAsAdded() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)

        let report = try store.merge([
            Fixture.channel("TF1", tvgID: "TF1.fr", streamID: "1"),
            Fixture.channel("M6", tvgID: "M6.fr", streamID: "2"),
        ], playlistID: "p1")

        XCTAssertEqual(report.added, 2)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(try store.count(playlistID: "p1"), 2)
    }

    func testReimportDistinguishesAddedUpdatedAndRemoved() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)

        try store.merge([
            Fixture.channel("TF1", tvgID: "TF1.fr", streamID: "1"),
            Fixture.channel("M6", tvgID: "M6.fr", streamID: "2"),
            Fixture.channel("Arte", tvgID: "Arte.fr", streamID: "3"),
        ], playlistID: "p1")

        // TF1 renommée, M6 conservée, Arte disparue, France 2 apparue.
        let report = try store.merge([
            Fixture.channel("TF1 HD", tvgID: "TF1.fr", streamID: "1"),
            Fixture.channel("M6", tvgID: "M6.fr", streamID: "2"),
            Fixture.channel("France 2", tvgID: "France2.fr", streamID: "4"),
        ], playlistID: "p1")

        XCTAssertEqual(report.added, 1, "France 2")
        XCTAssertEqual(report.updated, 2, "TF1 et M6")
        XCTAssertEqual(report.removed, 1, "Arte")
        XCTAssertEqual(try store.count(playlistID: "p1"), 3)
    }

    func testProviderChangingStreamIDsDoesNotRecreateChannels() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)

        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr", streamID: "1")],
                        playlistID: "p1")
        let before = try XCTUnwrap(store.channel(key: .channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")))

        // Le fournisseur réattribue ses identifiants : c'est le cas courant.
        let report = try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr", streamID: "98765")],
                                     playlistID: "p1")

        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.removed, 0)

        let after = try XCTUnwrap(store.channel(key: before.stableKey))
        XCTAssertEqual(after.id, before.id, "la ligne doit être mise à jour, pas recréée")
        XCTAssertEqual(after.streamId, "98765", "mais son stream_id doit suivre")
    }

    func testFavouritesAndOverridesSurviveAResync() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)
        let library = LibraryStore(database)

        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr", streamID: "1")],
                        playlistID: "p1")
        let key = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")

        try library.setFavorite(true, key: key, kind: .channel)
        try library.setOverride(ChannelOverrideRecord(channelKey: key, customName: "La Une"))
        try library.recordProgress(key: key, position: 120, duration: 3600)

        // Resync complet, avec un identifiant de flux entièrement différent.
        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr", streamID: "42",
                                         url: "http://autre/live/u/p/42.ts")],
                        playlistID: "p1")

        XCTAssertTrue(try library.isFavorite(key), "le favori doit survivre")
        XCTAssertEqual(try library.override(for: key)?.customName, "La Une",
                       "le renommage doit survivre")
        XCTAssertEqual(try library.progress(for: key)?.positionSeconds, 120,
                       "la progression doit survivre")

        let channel = try XCTUnwrap(store.channel(key: key))
        XCTAssertEqual(channel.url, "http://autre/live/u/p/42.ts")
        XCTAssertEqual(channel.parsedChannel(applying: try library.override(for: key))?.name,
                       "La Une", "le nom personnalisé doit primer à la lecture")
    }

    func testDeletingAPlaylistCascadesToItsChannels() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)
        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr")], playlistID: "p1")

        try database.writer.write { db in
            _ = try PlaylistRecord.deleteAll(db)
        }
        XCTAssertEqual(try store.count(playlistID: "p1"), 0)
    }

    func testPlaylistsAreIsolatedFromEachOther() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database, id: "p1")
        try Fixture.playlist(in: database, id: "p2")
        let store = ChannelStore(database)

        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr")], playlistID: "p1")
        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr")], playlistID: "p2")

        XCTAssertEqual(try store.count(playlistID: "p1"), 1)
        XCTAssertEqual(try store.count(playlistID: "p2"), 1)

        // Un import vide sur p1 ne doit rien faire à p2.
        try store.merge([], playlistID: "p1")
        XCTAssertEqual(try store.count(playlistID: "p1"), 0)
        XCTAssertEqual(try store.count(playlistID: "p2"), 1)
    }

    func testStreamedImportMatchesBulkImport() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)

        let channels = (0..<12_000).map {
            Fixture.channel("Chaîne \($0)", tvgID: "c\($0)", streamID: "\($0)",
                            group: "G\($0 % 30)", sortIndex: $0)
        }

        // Petits lots, pour forcer plusieurs transactions.
        let session = try store.beginImport(playlistID: "p1", batchSize: 500)
        for channel in channels { try session.append(channel) }
        let report = try session.finish()

        XCTAssertEqual(report.added, 12_000)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(try store.count(playlistID: "p1"), 12_000)
    }

    func testSuspiciousResyncIsFlagged() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)

        let full = (0..<1_000).map { Fixture.channel("C\($0)", tvgID: "c\($0)") }
        try store.merge(full, playlistID: "p1")

        // Le serveur répond avec une playlist tronquée : l'app doit pouvoir refuser.
        let session = try store.beginImport(playlistID: "p1")
        for channel in full.prefix(10) { try session.append(channel) }
        let report = try session.finish()

        XCTAssertEqual(report.previousTotal, 1_000)
        XCTAssertTrue(report.looksSuspicious)
        XCTAssertFalse(MergeReport(added: 990, updated: 10, removed: 0, previousTotal: 1_000)
            .looksSuspicious)
    }

    func testPlaylistLastSyncIsStamped() throws {
        let database = try Fixture.database()
        let playlist = try Fixture.playlist(in: database)
        XCTAssertTrue(playlist.isStale)

        try ChannelStore(database).merge([Fixture.channel("TF1")], playlistID: "p1")

        let refreshed = try database.reader.read { try PlaylistRecord.fetchOne($0, key: "p1") }
        XCTAssertNotNil(refreshed?.lastSyncAt)
        XCTAssertFalse(try XCTUnwrap(refreshed).isStale)
    }
}

final class ChannelQueryTests: XCTestCase {

    private func populated() throws -> (UHFDatabase, ChannelStore) {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)
        try store.merge([
            Fixture.channel("TF1", tvgID: "TF1.fr", group: "Généralistes", sortIndex: 0),
            Fixture.channel("France 2", tvgID: "France2.fr", group: "Généralistes", sortIndex: 1),
            Fixture.channel("Canal+ Séries", tvgID: "CanalSeries.fr", group: "Cinéma", sortIndex: 2),
            Fixture.channel("beIN SPORTS 1", tvgID: "beIN1.fr", group: "Sport", sortIndex: 3),
            ParsedChannel(name: "Hot XXX", url: URL(string: "http://srv/x.ts")!,
                          groupTitle: "XXX", tvgID: "xxx.1", sortIndex: 4),
        ], playlistID: "p1")
        return (database, store)
    }

    func testGroupsAreOrderedByPopulation() throws {
        let (_, store) = try populated()
        let groups = try store.groups(playlistID: "p1")

        XCTAssertEqual(groups.first?.name, "Généralistes")
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertFalse(groups.contains { $0.name == "XXX" },
                       "les catégories adulte sont filtrées par défaut")
    }

    func testAdultChannelsAreHiddenByDefault() throws {
        let (_, store) = try populated()
        XCTAssertEqual(try store.channels(playlistID: "p1").count, 4)
        XCTAssertEqual(try store.channels(playlistID: "p1", includeAdult: true).count, 5)
    }

    func testFilteringByGroupAndOrdering() throws {
        let (_, store) = try populated()
        let generalistes = try store.channels(playlistID: "p1", group: "Généralistes")
        XCTAssertEqual(generalistes.map(\.name), ["TF1", "France 2"])
    }

    func testHiddenChannelsAreExcludedEverywhere() throws {
        let (database, store) = try populated()
        let key = StableKey.channel(playlistID: "p1", tvgID: "beIN1.fr", name: "beIN SPORTS 1")
        try LibraryStore(database).setOverride(
            ChannelOverrideRecord(channelKey: key, isHidden: true))

        XCTAssertEqual(try store.channels(playlistID: "p1").count, 3)
        XCTAssertTrue(try store.search("bein").isEmpty)
        XCTAssertFalse(try store.groups(playlistID: "p1").contains { $0.name == "Sport" })
    }

    // MARK: - Recherche

    func testSearchIsPrefixBasedAndAccentInsensitive() throws {
        let (_, store) = try populated()
        XCTAssertEqual(try store.search("fran").map(\.name), ["France 2"])
        XCTAssertEqual(try store.search("generalistes").count, 2,
                       "la recherche doit ignorer les accents et couvrir le groupe")
    }

    func testSearchHandlesPunctuationWithoutFailing() throws {
        let (_, store) = try populated()
        // « Canal+ » contient un opérateur FTS5 : sans échappement, la requête échoue.
        XCTAssertEqual(try store.search("canal+").map(\.name), ["Canal+ Séries"])
        XCTAssertEqual(try store.search("\"").count, 0, "une saisie absurde ne doit pas jeter")
        XCTAssertEqual(try store.search("").count, 0)
    }

    func testSearchIsCaseInsensitiveAndMultiWord() throws {
        let (_, store) = try populated()
        XCTAssertEqual(try store.search("BEIN spo").map(\.name), ["beIN SPORTS 1"])
    }

    func testSearchExcludesAdultByDefault() throws {
        let (_, store) = try populated()
        XCTAssertTrue(try store.search("hot").isEmpty)
        XCTAssertEqual(try store.search("hot", includeAdult: true).count, 1)
    }

    func testSearchIndexFollowsRenamesAndDeletions() throws {
        let (_, store) = try populated()
        XCTAssertEqual(try store.search("tf1").count, 1)

        // Resync qui renomme TF1 et supprime beIN : l'index plein texte doit suivre.
        try store.merge([Fixture.channel("La Une", tvgID: "TF1.fr")], playlistID: "p1")

        XCTAssertTrue(try store.search("bein").isEmpty, "chaîne supprimée")
        XCTAssertEqual(try store.search("une").count, 1, "chaîne renommée")
    }
}
