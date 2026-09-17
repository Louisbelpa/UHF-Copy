import XCTest
import UHFCore
@testable import UHFStore

final class EPGStoreTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_705_320_000)   // 2024-01-15 12:00 UTC

    private func programme(_ channel: String, offsetHours: Double, duration: Double = 1,
                           title: String) -> EPGProgramme {
        let start = base.addingTimeInterval(offsetHours * 3600)
        return EPGProgramme(channelID: channel, start: start,
                            stop: start.addingTimeInterval(duration * 3600), title: title)
    }

    private func populated(tvgShift: TimeInterval = 0) throws -> (UHFDatabase, EPGStore) {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)

        var tf1 = Fixture.channel("TF1", tvgID: "TF1.fr", streamID: "1")
        tf1.tvgShift = tvgShift
        try ChannelStore(database).merge([tf1, Fixture.channel("M6", tvgID: "M6.fr", streamID: "2")],
                                         playlistID: "p1")

        let store = EPGStore(database)
        let session = try store.beginImport(playlistID: "p1")
        try session.append(channel: EPGChannel(xmltvID: "TF1.fr", displayNames: ["TF1"]))
        try session.append(channel: EPGChannel(xmltvID: "M6.fr", displayNames: ["M6"]))
        try session.append(programme: programme("TF1.fr", offsetHours: -1, title: "Avant"))
        try session.append(programme: programme("TF1.fr", offsetHours: 0, title: "En cours"))
        try session.append(programme: programme("TF1.fr", offsetHours: 1, title: "Suivant"))
        try session.append(programme: programme("TF1.fr", offsetHours: 2, title: "Plus tard"))
        try session.append(programme: programme("M6.fr", offsetHours: 0, title: "M6 en cours"))
        try session.finish()

        try store.saveLinks([
            (StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1"), "TF1.fr", 3),
            (StableKey.channel(playlistID: "p1", tvgID: "M6.fr", name: "M6"), "M6.fr", 3),
        ], playlistID: "p1")

        return (database, store)
    }

    // MARK: - Import

    func testImportCountsProgrammes() throws {
        let (_, store) = try populated()
        XCTAssertEqual(try store.programmeCount(playlistID: "p1"), 5)
        XCTAssertEqual(try store.epgChannels(playlistID: "p1").count, 2)
    }

    func testOrphanedProgrammesAreSkippedNotFatal() throws {
        let database = try Fixture.database()
        try Fixture.playlist(in: database)
        let store = EPGStore(database)

        let session = try store.beginImport(playlistID: "p1")
        try session.append(channel: EPGChannel(xmltvID: "TF1.fr", displayNames: ["TF1"]))
        try session.append(programme: programme("TF1.fr", offsetHours: 0, title: "OK"))
        // Chaîne jamais déclarée dans le fichier : cas très fréquent.
        try session.append(programme: programme("Inconnue.fr", offsetHours: 0, title: "Orphelin"))
        try session.finish()

        XCTAssertEqual(session.orphanedProgrammes, 1)
        XCTAssertEqual(try store.programmeCount(playlistID: "p1"), 1)
    }

    func testReimportReplacesTheGuide() throws {
        let (database, store) = try populated()

        let session = try store.beginImport(playlistID: "p1")
        try session.append(channel: EPGChannel(xmltvID: "TF1.fr", displayNames: ["TF1"]))
        try session.append(programme: programme("TF1.fr", offsetHours: 0, title: "Nouveau"))
        let report = try session.finish()

        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.removed, 5, "l'ancien guide est remplacé")
        XCTAssertEqual(try store.programmeCount(playlistID: "p1"), 1)

        let key = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        let found = try store.nowNext(channelKeys: [key], playlistID: "p1", at: base)
        XCTAssertEqual(found[key]?.current?.title, "Nouveau")
        _ = database
    }

    func testRemindersSurviveAGuideReimport() throws {
        let (database, store) = try populated()
        let library = LibraryStore(database)
        let start = base.addingTimeInterval(3600)

        try library.addReminder(ReminderRecord(xmltvId: "TF1.fr", programmeStart: start,
                                               title: "Suivant"))

        // Réimport complet : les lignes `programmes` sont toutes recréées.
        let session = try store.beginImport(playlistID: "p1")
        try session.append(channel: EPGChannel(xmltvID: "TF1.fr", displayNames: ["TF1"]))
        try session.append(programme: programme("TF1.fr", offsetHours: 1, title: "Suivant"))
        try session.finish()

        XCTAssertNotNil(try library.reminder(xmltvId: "TF1.fr", programmeStart: start),
                        "un rappel est rattaché au couple (chaîne, heure), pas à une ligne")
    }

    // MARK: - Now / Next

    func testNowNextReturnsCurrentAndFollowing() throws {
        let (_, store) = try populated()
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        let m6 = StableKey.channel(playlistID: "p1", tvgID: "M6.fr", name: "M6")

        let result = try store.nowNext(channelKeys: [tf1, m6], playlistID: "p1",
                                       at: base.addingTimeInterval(600))

        XCTAssertEqual(result[tf1]?.current?.title, "En cours")
        XCTAssertEqual(result[tf1]?.next?.title, "Suivant")
        XCTAssertEqual(result[m6]?.current?.title, "M6 en cours")
        XCTAssertNil(result[m6]?.next)
    }

    func testNowNextIsEmptyForUnlinkedChannels() throws {
        let (_, store) = try populated()
        let unknown = StableKey.channel(playlistID: "p1", tvgID: "Absente.fr", name: "Absente")
        XCTAssertTrue(try store.nowNext(channelKeys: [unknown], playlistID: "p1", at: base).isEmpty)
        XCTAssertTrue(try store.nowNext(channelKeys: [], playlistID: "p1", at: base).isEmpty)
    }

    func testTvgShiftIsAppliedToTheGuide() throws {
        // Guide décalé d'une heure : à 12 h, c'est « Avant » qui doit être en cours.
        let (_, store) = try populated(tvgShift: 3600)
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")

        let result = try store.nowNext(channelKeys: [tf1], playlistID: "p1",
                                       at: base.addingTimeInterval(600))
        XCTAssertEqual(result[tf1]?.current?.title, "Avant")
        XCTAssertEqual(result[tf1]?.next?.title, "En cours")
    }

    func testProgressOfCurrentProgramme() throws {
        let (_, store) = try populated()
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")
        let result = try store.nowNext(channelKeys: [tf1], playlistID: "p1",
                                       at: base.addingTimeInterval(1800))
        let progress = try XCTUnwrap(result[tf1]?.current?.progress(at: base.addingTimeInterval(1800)))
        XCTAssertEqual(progress, 0.5, accuracy: 0.01)
    }

    // MARK: - Grille

    func testGridQueryIsBoundedByTheRequestedWindow() throws {
        let (_, store) = try populated()
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")

        let window = try store.programmes(channelKey: tf1, playlistID: "p1",
                                          from: base, to: base.addingTimeInterval(7200))
        XCTAssertEqual(window.map(\.title), ["En cours", "Suivant"])
    }

    // MARK: - Correspondances manuelles

    func testManualLinkIsNotOverwrittenByAnAutomaticOne() throws {
        let (_, store) = try populated()
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")

        try store.setManualLink(channelKey: tf1, xmltvID: "M6.fr", playlistID: "p1")
        // Un nouvel appariement automatique repropose TF1.fr : il doit être ignoré.
        try store.saveLinks([(tf1, "TF1.fr", 3)], playlistID: "p1")

        let link = try XCTUnwrap(store.link(for: tf1, playlistID: "p1"))
        XCTAssertEqual(link.xmltvId, "M6.fr", "le choix de l'utilisateur prime")
        XCTAssertTrue(link.isManual)
    }

    func testAutomaticLinkIsRefreshedWhenNotManual() throws {
        let (_, store) = try populated()
        let tf1 = StableKey.channel(playlistID: "p1", tvgID: "TF1.fr", name: "TF1")

        try store.saveLinks([(tf1, "M6.fr", 1)], playlistID: "p1")
        let link = try XCTUnwrap(store.link(for: tf1, playlistID: "p1"))
        XCTAssertEqual(link.xmltvId, "M6.fr")
        XCTAssertEqual(link.confidence, 1)
    }

    // MARK: - Purge

    func testPurgeRemovesExpiredProgrammesOnly() throws {
        let (_, store) = try populated()
        let removed = try store.purge(before: base)

        XCTAssertEqual(removed, 1, "seul « Avant » est entièrement passé")
        XCTAssertEqual(try store.programmeCount(playlistID: "p1"), 4)
    }

    func testRetentionWindowCoversYesterdayAndAWeekAhead() {
        let window = EPGStore.retentionWindow(from: base)
        XCTAssertEqual(window.lowerBound, base.addingTimeInterval(-86_400))
        XCTAssertEqual(window.upperBound, base.addingTimeInterval(7 * 86_400))
    }

    func testDeletingPlaylistCascadesToGuide() throws {
        let (database, store) = try populated()
        try database.writer.write { db in _ = try PlaylistRecord.deleteAll(db) }
        XCTAssertEqual(try store.programmeCount(playlistID: "p1"), 0)
    }
}
