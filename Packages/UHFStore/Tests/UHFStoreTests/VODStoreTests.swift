import XCTest
import UHFCore
@testable import UHFStore

final class VODStoreTests: XCTestCase {

    private func store() throws -> (UHFDatabase, VODStore) {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        return (database, VODStore(database))
    }

    func testMoviesMergeAndPurge() throws {
        let (_, store) = try store()
        try store.merge(movies: [
            ParsedMovie(streamID: "1", title: "Inception", year: 2010),
            ParsedMovie(streamID: "2", title: "Heat", year: 1995),
        ], playlistID: "p1")

        let report = try store.merge(movies: [
            ParsedMovie(streamID: "99", title: "Inception", year: 2010),
            ParsedMovie(streamID: "3", title: "Sicario", year: 2015),
        ], playlistID: "p1")

        XCTAssertEqual(report.added, 1, "Sicario")
        XCTAssertEqual(report.updated, 1, "Inception, malgré son nouveau stream_id")
        XCTAssertEqual(report.removed, 1, "Heat")
        XCTAssertEqual(try store.movieCount(playlistID: "p1"), 2)
    }

    func testWatchProgressSurvivesAMovieReimport() throws {
        let (database, store) = try store()
        let library = LibraryStore(database)

        try store.merge(movies: [ParsedMovie(streamID: "1", title: "Inception", year: 2010)],
                        playlistID: "p1")
        let key = StableKey.movie(playlistID: "p1", title: "Inception", year: 2010)
        try library.recordProgress(key: key, position: 3600, duration: 8880)

        try store.merge(movies: [ParsedMovie(streamID: "77", title: "Inception", year: 2010)],
                        playlistID: "p1")

        XCTAssertEqual(try library.progress(for: key)?.positionSeconds, 3600)
    }

    func testEpisodesAreOrderedAndReplaced() throws {
        let (_, store) = try store()
        try store.merge(series: [ParsedSeries(seriesID: "s1", title: "The Wire")], playlistID: "p1")
        let key = StableKey.series(playlistID: "p1", title: "The Wire")

        try store.replaceEpisodes([
            ParsedEpisode(episodeID: "12", season: 1, number: 2, title: "S1E2"),
            ParsedEpisode(episodeID: "11", season: 1, number: 1, title: "S1E1"),
            ParsedEpisode(episodeID: "21", season: 2, number: 1, title: "S2E1"),
        ], seriesKey: key)

        XCTAssertEqual(try store.episodes(seriesKey: key).map(\.title), ["S1E1", "S1E2", "S2E1"])

        try store.replaceEpisodes([
            ParsedEpisode(episodeID: "11", season: 1, number: 1, title: "S1E1 remasterisé"),
        ], seriesKey: key)
        XCTAssertEqual(try store.episodes(seriesKey: key).map(\.title), ["S1E1 remasterisé"])
    }

    func testNextEpisodeFollowsWatchProgress() throws {
        let (database, store) = try store()
        let library = LibraryStore(database)
        try store.merge(series: [ParsedSeries(seriesID: "s1", title: "The Wire")], playlistID: "p1")
        let seriesKey = StableKey.series(playlistID: "p1", title: "The Wire")

        try store.replaceEpisodes([
            ParsedEpisode(episodeID: "11", season: 1, number: 1, title: "S1E1"),
            ParsedEpisode(episodeID: "12", season: 1, number: 2, title: "S1E2"),
        ], seriesKey: seriesKey)

        XCTAssertEqual(try store.nextEpisode(seriesKey: seriesKey)?.title, "S1E1")

        let first = StableKey.episode(seriesKey: seriesKey, season: 1, number: 1)
        try library.recordProgress(key: first, position: 2900, duration: 3000)   // terminé
        XCTAssertEqual(try store.nextEpisode(seriesKey: seriesKey)?.title, "S1E2")

        let second = StableKey.episode(seriesKey: seriesKey, season: 1, number: 2)
        try library.recordProgress(key: second, position: 2900, duration: 3000)
        XCTAssertNil(try store.nextEpisode(seriesKey: seriesKey), "série entièrement vue")
    }

    func testDeletingSeriesCascadesToEpisodes() throws {
        let (database, store) = try store()
        try store.merge(series: [ParsedSeries(seriesID: "s1", title: "The Wire")], playlistID: "p1")
        let key = StableKey.series(playlistID: "p1", title: "The Wire")
        try store.replaceEpisodes([ParsedEpisode(episodeID: "11", season: 1, number: 1, title: "A")],
                                  seriesKey: key)

        try store.merge(series: [], playlistID: "p1")
        XCTAssertTrue(try store.episodes(seriesKey: key).isEmpty)
        _ = database
    }
}

final class LibraryStoreTests: XCTestCase {

    func testFoldersKeepTheirFavouritesWhenDeleted() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        try ChannelStore(database).merge([Fixture.channel("TF1", tvgID: "TF1.fr")], playlistID: "p1")
        let library = LibraryStore(database)
        let key = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")

        let folder = try library.createFolder(name: "Enfants", pinHash: "abc")
        XCTAssertTrue(folder.isLocked)
        try library.setFavorite(true, key: key, kind: .channel, folderId: folder.id)
        XCTAssertEqual(try library.favoriteChannels(folderId: folder.id).count, 1)

        try library.deleteFolder(id: folder.id)
        XCTAssertEqual(try library.favoriteCount(), 1, "le favori remonte à la racine")
        XCTAssertEqual(try library.favoriteChannels().count, 1)
    }

    func testFavouriteOfADisappearedChannelIsKept() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = ChannelStore(database)
        let library = LibraryStore(database)

        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr")], playlistID: "p1")
        let key = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        try library.setFavorite(true, key: key, kind: .channel)

        // Le fournisseur renvoie une playlist incomplète.
        try store.merge([], playlistID: "p1")

        XCTAssertTrue(try library.isFavorite(key), "le favori ne doit pas être effacé")
        XCTAssertTrue(try library.favoriteChannels().isEmpty, "mais il n'est plus affichable")

        // La chaîne revient : le favori la retrouve.
        try store.merge([Fixture.channel("TF1", tvgID: "TF1.fr")], playlistID: "p1")
        XCTAssertEqual(try library.favoriteChannels().count, 1)
    }

    func testShortPlaybackDoesNotPolluteContinueWatching() throws {
        let database = try Fixture.database()
        let library = LibraryStore(database)
        let key = StableKey(rawValue: "mv_test")

        try library.recordProgress(key: key, position: 12, duration: 5400)
        XCTAssertNil(try library.progress(for: key), "un zapping n'est pas une reprise")

        try library.recordProgress(key: key, position: 600, duration: 5400)
        XCTAssertEqual(try library.continueWatching().count, 1)

        try library.recordProgress(key: key, position: 5300, duration: 5400)
        XCTAssertTrue(try library.continueWatching().isEmpty, "terminé à 98 %")
    }

    func testUserDataRoundTripsForICloudSync() throws {
        let database = try Fixture.database()
        let library = LibraryStore(database)
        let key = StableKey(rawValue: "ch_abc")

        let folder = try library.createFolder(name: "Sport")
        try library.setFavorite(true, key: key, kind: .channel, folderId: folder.id)
        try library.setOverride(ChannelOverrideRecord(channelKey: key, customName: "Ma chaîne"))
        try library.recordProgress(key: key, position: 300, duration: 3600)

        let snapshot = try library.exportUserData()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LibraryStore.UserDataSnapshot.self, from: encoded)

        let fresh = try Fixture.database()
        try LibraryStore(fresh).importUserData(decoded)

        XCTAssertTrue(try LibraryStore(fresh).isFavorite(key))
        XCTAssertEqual(try LibraryStore(fresh).override(for: key)?.customName, "Ma chaîne")
        XCTAssertEqual(try LibraryStore(fresh).folders().count, 1)
    }

    func testMoreRecentProgressWinsOnMerge() throws {
        let database = try Fixture.database()
        let library = LibraryStore(database)
        let key = StableKey(rawValue: "mv_abc")
        let now = Date()

        try library.recordProgress(key: key, position: 600, duration: 3600)
        try database.writer.write { db in
            try WatchProgressRecord(targetKey: key, positionSeconds: 600,
                                    durationSeconds: 3600, updatedAt: now).upsert(db)
        }

        // Un autre appareil a regardé plus loin, plus tard.
        let newer = WatchProgressRecord(targetKey: key, positionSeconds: 1800,
                                        durationSeconds: 3600,
                                        updatedAt: now.addingTimeInterval(60))
        try library.importUserData(.init(folders: [], favorites: [], overrides: [],
                                         progress: [newer], reminders: []))
        XCTAssertEqual(try library.progress(for: key)?.positionSeconds, 1800)

        // Une position plus ancienne ne doit pas faire reculer la lecture.
        let older = WatchProgressRecord(targetKey: key, positionSeconds: 60,
                                        durationSeconds: 3600,
                                        updatedAt: now.addingTimeInterval(-60))
        try library.importUserData(.init(folders: [], favorites: [], overrides: [],
                                         progress: [older], reminders: []))
        XCTAssertEqual(try library.progress(for: key)?.positionSeconds, 1800)
    }

    func testExpiredRemindersArePrunedWhenListed() throws {
        let database = try Fixture.database()
        let library = LibraryStore(database)

        try library.addReminder(ReminderRecord(xmltvId: "A", programmeStart: Date().addingTimeInterval(3600),
                                               title: "À venir"))
        try library.addReminder(ReminderRecord(xmltvId: "B", programmeStart: Date().addingTimeInterval(-7200),
                                               title: "Passé"))

        let pending = try library.pendingReminders()
        XCTAssertEqual(pending.map(\.title), ["À venir"])
    }

    func testEmptyOverrideIsDeletedRatherThanStored() throws {
        let database = try Fixture.database()
        let library = LibraryStore(database)
        let key = StableKey(rawValue: "ch_abc")

        try library.setOverride(ChannelOverrideRecord(channelKey: key, customName: "X"))
        XCTAssertNotNil(try library.override(for: key))

        try library.setOverride(ChannelOverrideRecord(channelKey: key))
        XCTAssertNil(try library.override(for: key))
    }
}
