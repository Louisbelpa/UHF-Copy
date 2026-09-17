import Foundation
import GRDB
import UHFCore

// Les enregistrements collent au schéma SQL, pas aux modèles métier de `UHFCore` :
// c'est délibéré. Le catalogue est réécrit en masse et doit rester plat et bon marché
// à insérer ; la conversion vers les types métier se fait à la lecture, là où le
// volume est faible.

public struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "playlists"

    public var id: String
    public var name: String
    public var kind: String
    public var url: String
    public var credentialsRef: String?
    public var epgURL: String?
    public var userAgent: String?
    public var referer: String?
    public var lastSyncAt: Date?
    public var refreshInterval: TimeInterval
    public var sortIndex: Int
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString,
                name: String,
                kind: PlaylistKind,
                url: URL,
                credentialsRef: String? = nil,
                epgURL: URL? = nil,
                userAgent: String? = nil,
                referer: String? = nil,
                lastSyncAt: Date? = nil,
                refreshInterval: TimeInterval = 86_400,
                sortIndex: Int = 0,
                isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind.rawValue
        self.url = url.absoluteString
        self.credentialsRef = credentialsRef
        self.epgURL = epgURL?.absoluteString
        self.userAgent = userAgent
        self.referer = referer
        self.lastSyncAt = lastSyncAt
        self.refreshInterval = refreshInterval
        self.sortIndex = sortIndex
        self.isEnabled = isEnabled
    }

    public var playlistKind: PlaylistKind? { PlaylistKind(rawValue: kind) }
    public var isStale: Bool {
        guard let lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSyncAt) > refreshInterval
    }
}

public struct ChannelRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "channels"

    public var id: Int64?
    public var playlistId: String
    public var key: String
    public var name: String
    public var url: String
    public var streamId: String?
    public var logoURL: String?
    public var groupTitle: String?
    public var tvgId: String?
    public var tvgShift: TimeInterval
    public var catchupMode: String?
    public var catchupDays: Int?
    public var catchupSource: String?
    public var httpHeaders: [String: String]?
    public var sortIndex: Int
    public var isAdult: Bool
    public var syncToken: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(parsed: ParsedChannel, playlistID: String, syncToken: String) {
        self.id = nil
        self.playlistId = playlistID
        self.key = parsed.stableKey(playlistID: playlistID).rawValue
        self.name = parsed.name
        self.url = parsed.url.absoluteString
        self.streamId = parsed.streamID
        self.logoURL = parsed.logoURL?.absoluteString
        self.groupTitle = parsed.groupTitle
        self.tvgId = parsed.tvgID
        self.tvgShift = parsed.tvgShift
        self.catchupMode = parsed.catchup?.rawValue
        self.catchupDays = parsed.catchupDays
        self.catchupSource = parsed.catchupSource
        self.httpHeaders = parsed.httpHeaders.isEmpty ? nil : parsed.httpHeaders
        self.sortIndex = parsed.sortIndex
        self.isAdult = parsed.isLikelyAdult
        self.syncToken = syncToken
    }

    public var stableKey: StableKey { StableKey(rawValue: key) }

    /// Reconstruit le modèle métier, en appliquant les personnalisations de
    /// l'utilisateur si elles ont été jointes.
    public func parsedChannel(applying override: ChannelOverrideRecord? = nil) -> ParsedChannel? {
        guard let url = URL(string: url) else { return nil }
        return ParsedChannel(
            name: override?.customName ?? name,
            url: url,
            streamID: streamId,
            logoURL: (override?.customLogoURL ?? logoURL).flatMap { URL(string: $0) },
            groupTitle: groupTitle,
            tvgID: tvgId,
            tvgShift: tvgShift,
            catchup: catchupMode.flatMap { CatchupMode(rawValue: $0) },
            catchupDays: catchupDays,
            catchupSource: catchupSource,
            httpHeaders: httpHeaders ?? [:],
            sortIndex: override?.customSortIndex ?? sortIndex)
    }
}

public struct MovieRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "movies"

    public var id: Int64?
    public var playlistId: String
    public var key: String
    public var streamId: String
    public var title: String
    public var year: Int?
    public var posterURL: String?
    public var rating: Double?
    public var plot: String?
    public var containerExtension: String
    public var categoryId: String?
    public var syncToken: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public init(parsed: ParsedMovie, playlistID: String, syncToken: String) {
        self.id = nil
        self.playlistId = playlistID
        self.key = StableKey.movie(playlistID: playlistID, title: parsed.title, year: parsed.year).rawValue
        self.streamId = parsed.streamID
        self.title = parsed.title
        self.year = parsed.year
        self.posterURL = parsed.posterURL?.absoluteString
        self.rating = parsed.rating
        self.plot = parsed.plot
        self.containerExtension = parsed.containerExtension
        self.categoryId = parsed.categoryID
        self.syncToken = syncToken
    }
}

public struct SeriesRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "series"

    public var id: Int64?
    public var playlistId: String
    public var key: String
    public var seriesId: String
    public var title: String
    public var posterURL: String?
    public var plot: String?
    public var categoryId: String?
    public var syncToken: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public init(parsed: ParsedSeries, playlistID: String, syncToken: String) {
        self.id = nil
        self.playlistId = playlistID
        self.key = StableKey.series(playlistID: playlistID, title: parsed.title).rawValue
        self.seriesId = parsed.seriesID
        self.title = parsed.title
        self.posterURL = parsed.posterURL?.absoluteString
        self.plot = parsed.plot
        self.categoryId = parsed.categoryID
        self.syncToken = syncToken
    }
}

public struct EpisodeRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "episodes"

    public var id: Int64?
    public var seriesRowId: Int64
    public var key: String
    public var episodeId: String
    public var season: Int
    public var number: Int
    public var title: String
    public var containerExtension: String
    public var plot: String?
    public var durationSeconds: Int?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public init(parsed: ParsedEpisode, seriesRowID: Int64, seriesKey: StableKey) {
        self.id = nil
        self.seriesRowId = seriesRowID
        self.key = StableKey.episode(seriesKey: seriesKey,
                                     season: parsed.season,
                                     number: parsed.number).rawValue
        self.episodeId = parsed.episodeID
        self.season = parsed.season
        self.number = parsed.number
        self.title = parsed.title
        self.containerExtension = parsed.containerExtension
        self.plot = parsed.plot
        self.durationSeconds = parsed.durationSeconds
    }
}

public struct EPGChannelRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "epgChannels"

    public var id: Int64?
    public var playlistId: String
    public var xmltvId: String
    public var displayName: String?
    public var iconURL: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ProgrammeRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "programmes"

    public var id: Int64?
    public var epgChannelId: Int64
    public var startAt: Double
    public var endAt: Double
    public var title: String
    public var subtitle: String?
    public var summary: String?
    public var categories: [String]?
    public var iconURL: String?
    public var episodeNumber: String?
    public var syncToken: String = ""

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var start: Date { Date(timeIntervalSince1970: startAt) }
    public var end: Date { Date(timeIntervalSince1970: endAt) }
    public var duration: TimeInterval { endAt - startAt }

    /// Progression de 0 à 1 du programme en cours, pour la barre des listes de chaînes.
    public func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max((date.timeIntervalSince1970 - startAt) / duration, 0), 1)
    }
}

public struct ChannelEPGLinkRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "channelEPGLinks"

    public var playlistId: String
    public var channelKey: String
    public var xmltvId: String
    /// Valeur brute de `EPGMatcher.Confidence`.
    public var confidence: Int
    /// Corrigé à la main par l'utilisateur : ne doit jamais être écrasé par un import.
    public var isManual: Bool

    public init(playlistId: String, channelKey: String, xmltvId: String,
                confidence: Int, isManual: Bool = false) {
        self.playlistId = playlistId
        self.channelKey = channelKey
        self.xmltvId = xmltvId
        self.confidence = confidence
        self.isManual = isManual
    }
}

// MARK: - Données utilisateur

public enum FavoriteKind: String, Codable, Sendable {
    case channel, movie, series, episode
}

public struct FavoriteRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "favorites"

    public var targetKey: String
    public var targetKind: String
    public var folderId: String?
    public var sortIndex: Int
    public var addedAt: Date

    public init(targetKey: StableKey, kind: FavoriteKind,
                folderId: String? = nil, sortIndex: Int = 0, addedAt: Date = Date()) {
        self.targetKey = targetKey.rawValue
        self.targetKind = kind.rawValue
        self.folderId = folderId
        self.sortIndex = sortIndex
        self.addedAt = addedAt
    }
}

public struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "folders"

    public var id: String
    public var name: String
    public var pinHash: String?
    public var sortIndex: Int

    public init(id: String = UUID().uuidString, name: String,
                pinHash: String? = nil, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.pinHash = pinHash
        self.sortIndex = sortIndex
    }

    public var isLocked: Bool { pinHash != nil }
}

public struct ChannelOverrideRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "channelOverrides"

    public var channelKey: String
    public var customName: String?
    public var customLogoURL: String?
    public var isHidden: Bool
    public var customSortIndex: Int?

    public init(channelKey: StableKey, customName: String? = nil,
                customLogoURL: String? = nil, isHidden: Bool = false,
                customSortIndex: Int? = nil) {
        self.channelKey = channelKey.rawValue
        self.customName = customName
        self.customLogoURL = customLogoURL
        self.isHidden = isHidden
        self.customSortIndex = customSortIndex
    }

    /// Une personnalisation vide n'a pas à occuper une ligne.
    public var isEmpty: Bool {
        customName == nil && customLogoURL == nil && !isHidden && customSortIndex == nil
    }
}

public struct WatchProgressRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "watchProgress"

    public var targetKey: String
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var updatedAt: Date

    public init(targetKey: StableKey, positionSeconds: Double,
                durationSeconds: Double, updatedAt: Date = Date()) {
        self.targetKey = targetKey.rawValue
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.updatedAt = updatedAt
    }

    public var fraction: Double {
        durationSeconds > 0 ? min(max(positionSeconds / durationSeconds, 0), 1) : 0
    }

    /// Au-delà de 95 %, le contenu est considéré comme terminé et sort de la
    /// rangée « continuer à regarder ».
    public var isFinished: Bool { fraction >= 0.95 }
}

public struct ReminderRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "reminders"

    public var id: String
    public var xmltvId: String
    public var programmeStartAt: Double
    public var title: String
    public var fireAt: Double
    public var notificationId: String?

    public init(id: String = UUID().uuidString, xmltvId: String, programmeStart: Date,
                title: String, leadTime: TimeInterval = 300, notificationId: String? = nil) {
        self.id = id
        self.xmltvId = xmltvId
        self.programmeStartAt = programmeStart.timeIntervalSince1970
        self.title = title
        self.fireAt = programmeStart.timeIntervalSince1970 - leadTime
        self.notificationId = notificationId
    }

    public var fireDate: Date { Date(timeIntervalSince1970: fireAt) }
}

public struct PlaybackDecisionRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "playbackDecisions"

    public var targetKey: String
    public var engine: String
    public var decidedAt: Date

    public init(targetKey: StableKey, engine: String, decidedAt: Date = Date()) {
        self.targetKey = targetKey.rawValue
        self.engine = engine
        self.decidedAt = decidedAt
    }
}
