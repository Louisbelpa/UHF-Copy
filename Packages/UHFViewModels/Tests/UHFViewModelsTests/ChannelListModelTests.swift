import XCTest
import UHFCore
import UHFStore
@testable import UHFViewModels

/// - Note: les méthodes de test sont `async` bien qu'elles n'attendent rien.
///   `swift-corelibs-xctest` ne sait pas découvrir une méthode synchrone isolée à
///   `@MainActor` — il échoue à la conversion de type au lancement. Sur les
///   plateformes Apple, la forme synchrone fonctionnerait.
@MainActor
final class ChannelListModelTests: XCTestCase {

    private func makeDatabase(channelCount: Int = 250) throws -> UHFDatabase {
        let database = try UHFDatabase.inMemory()
        let playlist = PlaylistRecord(id: "p1", name: "Source", kind: .m3u,
                                      url: URL(string: "http://srv/liste.m3u")!)
        try database.writer.write { try playlist.insert($0) }

        let channels = (0..<channelCount).map { index in
            ParsedChannel(name: "Chaîne \(index)",
                          url: URL(string: "http://srv/live/\(index).ts")!,
                          groupTitle: index % 2 == 0 ? "Généralistes" : "Sport",
                          tvgID: "ch\(index).fr",
                          sortIndex: index)
        }
        try ChannelStore(database).merge(channels, playlistID: "p1")
        return database
    }

    func testPaginatesRatherThanLoadingEverything() async throws {
        let model = ChannelListModel(database: try makeDatabase(), playlistID: "p1", pageSize: 100)

        model.reloadFromScratch()
        XCTAssertEqual(model.rows.count, 100)
        XCTAssertTrue(model.hasMore)

        model.loadNextPage()
        XCTAssertEqual(model.rows.count, 200)

        model.loadNextPage()
        XCTAssertEqual(model.rows.count, 250)
        XCTAssertFalse(model.hasMore, "dernière page incomplète : il n'y a plus rien")

        model.loadNextPage()
        XCTAssertEqual(model.rows.count, 250, "ne doit plus rien charger")
    }

    func testRowsKeepTheSourceOrder() async throws {
        let model = ChannelListModel(database: try makeDatabase(channelCount: 5),
                                     playlistID: "p1")
        model.reloadFromScratch()
        XCTAssertEqual(model.rows.map(\.displayName),
                       ["Chaîne 0", "Chaîne 1", "Chaîne 2", "Chaîne 3", "Chaîne 4"])
    }

    func testChangingFilterResetsPagination() async throws {
        let model = ChannelListModel(database: try makeDatabase(), playlistID: "p1", pageSize: 100)
        model.reloadFromScratch()
        model.loadNextPage()
        XCTAssertEqual(model.rows.count, 200)

        model.filter = .group("Sport")
        XCTAssertEqual(model.rows.count, 100, "la pagination repart de zéro")
        XCTAssertTrue(model.rows.allSatisfy { $0.channel.groupTitle == "Sport" })
    }

    func testFavoriteToggleUpdatesInPlace() async throws {
        let database = try makeDatabase(channelCount: 3)
        let model = ChannelListModel(database: database, playlistID: "p1")
        model.reloadFromScratch()

        let first = try XCTUnwrap(model.rows.first)
        XCTAssertFalse(first.isFavorite)

        model.toggleFavorite(first)
        XCTAssertTrue(model.rows[0].isFavorite, "l'étoile doit répondre sans recharger")
        XCTAssertTrue(try LibraryStore(database).isFavorite(first.key))

        model.toggleFavorite(model.rows[0])
        XCTAssertFalse(model.rows[0].isFavorite)
        XCTAssertFalse(try LibraryStore(database).isFavorite(first.key))
    }

    func testFavoritesFilterShowsOnlyFavourites() async throws {
        let database = try makeDatabase(channelCount: 10)
        let model = ChannelListModel(database: database, playlistID: "p1")
        model.reloadFromScratch()
        model.toggleFavorite(model.rows[3])

        model.filter = .favorites
        XCTAssertEqual(model.rows.map(\.displayName), ["Chaîne 3"])
        XCTAssertFalse(model.hasMore)
    }

    func testRenameAndRevert() async throws {
        let database = try makeDatabase(channelCount: 3)
        let model = ChannelListModel(database: database, playlistID: "p1")
        model.reloadFromScratch()
        let row = model.rows[0]

        model.rename(row, to: "La Une")
        XCTAssertEqual(model.rows[0].displayName, "La Une")

        // Un nom vide annule le renommage plutôt que d'enregistrer une ligne inutile.
        model.rename(model.rows[0], to: "  ")
        XCTAssertEqual(model.rows[0].displayName, "Chaîne 0")
        XCTAssertNil(try LibraryStore(database).override(for: row.key))
    }

    func testRenamingToTheSourceNameStoresNothing() async throws {
        let database = try makeDatabase(channelCount: 1)
        let model = ChannelListModel(database: database, playlistID: "p1")
        model.reloadFromScratch()

        model.rename(model.rows[0], to: "Chaîne 0")
        XCTAssertNil(try LibraryStore(database).override(for: model.rows[0].key))
    }

    func testHidingRemovesTheRowAndPersists() async throws {
        let database = try makeDatabase(channelCount: 5)
        let model = ChannelListModel(database: database, playlistID: "p1")
        model.reloadFromScratch()
        let row = model.rows[2]

        model.hide(row)
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertFalse(model.rows.contains { $0.id == row.id })

        model.reloadFromScratch()
        XCTAssertEqual(model.rows.count, 4, "la chaîne masquée ne revient pas")
    }

    func testGroupsAreListedForTheFilterBar() async throws {
        let model = ChannelListModel(database: try makeDatabase(channelCount: 10),
                                     playlistID: "p1")
        model.loadGroups()
        XCTAssertEqual(Set(model.groups.map(\.name)), ["Généralistes", "Sport"])
        XCTAssertEqual(model.groups.first?.count, 5)
    }

    // MARK: - Guide

    func testGuideDecoratesRowsAndCanBeRefreshedAlone() async throws {
        let database = try makeDatabase(channelCount: 3)
        let now = Date()
        let epg = EPGStore(database)

        let session = try epg.beginImport(playlistID: "p1")
        try session.append(channel: EPGChannel(xmltvID: "ch0.fr", displayNames: ["Chaîne 0"]))
        try session.append(programme: EPGProgramme(channelID: "ch0.fr",
                                                   start: now.addingTimeInterval(-900),
                                                   stop: now.addingTimeInterval(900),
                                                   title: "En cours"))
        try session.append(programme: EPGProgramme(channelID: "ch0.fr",
                                                   start: now.addingTimeInterval(900),
                                                   stop: now.addingTimeInterval(2700),
                                                   title: "Suivant"))
        try session.finish()
        try epg.saveLinks([(StableKey.channel(playlistID: "p1", tvgID: "ch0.fr", name: "Chaîne 0"),
                            "ch0.fr", 3)], playlistID: "p1")

        let model = ChannelListModel(database: database, playlistID: "p1")
        model.reloadFromScratch()

        XCTAssertEqual(model.rows[0].now?.title, "En cours")
        XCTAssertEqual(model.rows[0].next?.title, "Suivant")
        XCTAssertEqual(try XCTUnwrap(model.rows[0].progress(at: now)), 0.5, accuracy: 0.05)
        XCTAssertNil(model.rows[1].now, "chaîne sans correspondance dans le guide")

        // Une heure plus tard, sans recharger la liste : « Suivant » devient courant.
        model.refreshGuide(at: now.addingTimeInterval(1200))
        XCTAssertEqual(model.rows[0].now?.title, "Suivant")
    }

    func testAdultFilterIsRespected() async throws {
        let database = try UHFDatabase.inMemory()
        let playlist = PlaylistRecord(id: "p1", name: "S", kind: .m3u,
                                      url: URL(string: "http://srv/l.m3u")!)
        // En contexte asynchrone, GRDB résout `write` vers sa variante `async`.
        try await database.writer.write { try playlist.insert($0) }
        try ChannelStore(database).merge([
            ParsedChannel(name: "TF1", url: URL(string: "http://srv/1.ts")!, groupTitle: "FR"),
            ParsedChannel(name: "Hot", url: URL(string: "http://srv/2.ts")!, groupTitle: "XXX"),
        ], playlistID: "p1")

        let model = ChannelListModel(database: database, playlistID: "p1")
        model.reloadFromScratch()
        XCTAssertEqual(model.rows.count, 1)

        model.includeAdult = true
        XCTAssertEqual(model.rows.count, 2)
    }
}

@MainActor
final class SearchModelTests: XCTestCase {

    private func makeDatabase() throws -> UHFDatabase {
        let database = try UHFDatabase.inMemory()
        let playlist = PlaylistRecord(id: "p1", name: "S", kind: .m3u,
                                      url: URL(string: "http://srv/l.m3u")!)
        try database.writer.write { try playlist.insert($0) }
        try ChannelStore(database).merge([
            ParsedChannel(name: "TF1", url: URL(string: "http://srv/1.ts")!,
                          groupTitle: "Généralistes", tvgID: "TF1.fr"),
            ParsedChannel(name: "beIN SPORTS 1", url: URL(string: "http://srv/2.ts")!,
                          groupTitle: "Sport", tvgID: "beIN1.fr"),
            ParsedChannel(name: "beIN SPORTS 2", url: URL(string: "http://srv/3.ts")!,
                          groupTitle: "Sport", tvgID: "beIN2.fr"),
        ], playlistID: "p1")
        return database
    }

    func testDoesNotSearchBelowMinimumLength() async throws {
        let model = SearchModel(database: try makeDatabase(), playlistID: "p1",
                                debounce: .milliseconds(1))
        model.query = "b"
        XCTAssertFalse(model.shouldSearch)
        await model.searchNow()
        XCTAssertTrue(model.results.isEmpty,
                      "une seule lettre apparierait tout le catalogue")
    }

    func testFindsChannelsByPrefix() async throws {
        let model = SearchModel(database: try makeDatabase(), playlistID: "p1")
        model.query = "bein"
        await model.searchNow()
        XCTAssertEqual(model.results.count, 2)
        XCTAssertTrue(model.results.allSatisfy { $0.displayName.hasPrefix("beIN") })
    }

    func testDebounceCollapsesRapidTyping() async throws {
        let model = SearchModel(database: try makeDatabase(), playlistID: "p1",
                                debounce: .milliseconds(80))
        // Frappe rapide : seule la dernière requête doit aboutir.
        for text in ["be", "bei", "bein", "bein s"] { model.query = text }
        XCTAssertTrue(model.isSearching)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.query, "bein s")
    }

    func testClearingResetsEverything() async throws {
        let model = SearchModel(database: try makeDatabase(), playlistID: "p1")
        model.query = "bein"
        await model.searchNow()
        XCTAssertFalse(model.results.isEmpty)

        model.clear()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.isSearching)
    }

    func testPunctuationDoesNotBreakTheQuery() async throws {
        let model = SearchModel(database: try makeDatabase(), playlistID: "p1")
        model.query = "tf1+\""
        await model.searchNow()
        XCTAssertNil(model.errorMessage, "une saisie absurde ne doit pas remonter d'erreur")
    }

    func testResultsCarryFavouriteState() async throws {
        let database = try makeDatabase()
        let key = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        try LibraryStore(database).setFavorite(true, key: key, kind: .channel)

        let model = SearchModel(database: database, playlistID: "p1")
        model.query = "tf1"
        await model.searchNow()
        XCTAssertEqual(model.results.first?.isFavorite, true)
    }
}
