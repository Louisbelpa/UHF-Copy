import Foundation

// MARK: - Playlist

public enum PlaylistKind: String, Sendable, Codable, CaseIterable {
    case m3u
    case xtream
    case jellyfin
    case emby
    case plex
}

/// Une source configurée par l'utilisateur.
///
/// - Warning: `username` / `password` ne doivent **jamais** être écrits ici en clair.
///   Ils vivent dans le Keychain, et cette structure n'en porte qu'une référence.
public struct Playlist: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var kind: PlaylistKind
    public var url: URL
    /// Référence Keychain vers les identifiants, jamais les identifiants eux-mêmes.
    public var credentialsRef: String?
    public var epgURL: URL?
    public var userAgent: String?
    public var referer: String?
    public var lastSyncAt: Date?
    public var refreshInterval: TimeInterval

    public init(id: String = UUID().uuidString,
                name: String,
                kind: PlaylistKind,
                url: URL,
                credentialsRef: String? = nil,
                epgURL: URL? = nil,
                userAgent: String? = nil,
                referer: String? = nil,
                lastSyncAt: Date? = nil,
                refreshInterval: TimeInterval = 24 * 3600) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.credentialsRef = credentialsRef
        self.epgURL = epgURL
        self.userAgent = userAgent
        self.referer = referer
        self.lastSyncAt = lastSyncAt
        self.refreshInterval = refreshInterval
    }
}

// MARK: - Catch-up

/// Convention de replay annoncée par la source.
public enum CatchupMode: String, Sendable, Codable, Equatable {
    /// `catchup="default"` — l'URL de base reçoit les paramètres `utc`/`lutc`.
    case `default`
    /// `catchup="append"` — `catchup-source` est une chaîne à concaténer à l'URL live.
    case append
    /// `catchup="shift"` / `"timeshift"` — décalage en secondes via `utc`.
    case shift
    /// Convention Flussonic : `.../index-{utc}-{duration}.m3u8`.
    case flussonic
    /// Xtream : `streaming/timeshift.php`.
    case xtream

    public init?(rawAttribute: String) {
        switch rawAttribute.lowercased().trimmingCharacters(in: .whitespaces) {
        case "default", "1", "true": self = .default
        case "append": self = .append
        case "shift", "timeshift": self = .shift
        case "flussonic", "fs": self = .flussonic
        case "xc", "xtream": self = .xtream
        default: return nil
        }
    }
}

// MARK: - Chaîne

/// Une chaîne live telle que sortie d'un parseur, avant écriture en base.
public struct ParsedChannel: Sendable, Equatable {
    public var name: String
    public var url: URL
    /// Identifiant côté fournisseur. Instable par nature — ne jamais persister de
    /// référence utilisateur dessus, voir ``StableKey``.
    public var streamID: String?
    public var logoURL: URL?
    public var groupTitle: String?
    public var tvgID: String?
    public var tvgName: String?
    /// Décalage EPG en secondes (attribut `tvg-shift`, exprimé en heures dans le M3U).
    public var tvgShift: TimeInterval
    public var catchup: CatchupMode?
    public var catchupDays: Int?
    public var catchupSource: String?
    /// En-têtes HTTP imposés par la source (`#EXTVLCOPT`). Beaucoup de serveurs
    /// refusent le User-Agent par défaut d'AVPlayer.
    public var httpHeaders: [String: String]
    public var sortIndex: Int

    public init(name: String,
                url: URL,
                streamID: String? = nil,
                logoURL: URL? = nil,
                groupTitle: String? = nil,
                tvgID: String? = nil,
                tvgName: String? = nil,
                tvgShift: TimeInterval = 0,
                catchup: CatchupMode? = nil,
                catchupDays: Int? = nil,
                catchupSource: String? = nil,
                httpHeaders: [String: String] = [:],
                sortIndex: Int = 0) {
        self.name = name
        self.url = url
        self.streamID = streamID
        self.logoURL = logoURL
        self.groupTitle = groupTitle
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.tvgShift = tvgShift
        self.catchup = catchup
        self.catchupDays = catchupDays
        self.catchupSource = catchupSource
        self.httpHeaders = httpHeaders
        self.sortIndex = sortIndex
    }

    public func stableKey(playlistID: String) -> StableKey {
        .channel(playlistID: playlistID, tvgID: tvgID, name: name)
    }

    public var supportsCatchup: Bool { catchup != nil && (catchupDays ?? 0) > 0 }

    /// Heuristique de détection des catégories adulte, à filtrer par défaut.
    /// La règle 1.1.4 de l'App Store en fait un sujet de validation, pas de confort.
    public var isLikelyAdult: Bool {
        let haystack = ((groupTitle ?? "") + " " + name).lowercased()
        let markers = ["xxx", "adult", "porn", "18+", "erotic", "hustler", "brazzers", "playboy"]
        return markers.contains { haystack.contains($0) }
    }
}

// MARK: - EPG

public struct EPGChannel: Sendable, Equatable {
    public var xmltvID: String
    public var displayNames: [String]
    public var iconURL: URL?

    public init(xmltvID: String, displayNames: [String], iconURL: URL? = nil) {
        self.xmltvID = xmltvID
        self.displayNames = displayNames
        self.iconURL = iconURL
    }
}

public struct EPGProgramme: Sendable, Equatable {
    public var channelID: String
    public var start: Date
    public var stop: Date
    public var title: String
    public var subtitle: String?
    public var desc: String?
    public var categories: [String]
    public var iconURL: URL?
    public var episodeNumber: String?

    public init(channelID: String,
                start: Date,
                stop: Date,
                title: String,
                subtitle: String? = nil,
                desc: String? = nil,
                categories: [String] = [],
                iconURL: URL? = nil,
                episodeNumber: String? = nil) {
        self.channelID = channelID
        self.start = start
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        self.desc = desc
        self.categories = categories
        self.iconURL = iconURL
        self.episodeNumber = episodeNumber
    }

    public var duration: TimeInterval { stop.timeIntervalSince(start) }
}

// MARK: - VOD

public struct ParsedMovie: Sendable, Equatable {
    public var streamID: String
    public var title: String
    public var year: Int?
    public var posterURL: URL?
    public var rating: Double?
    public var plot: String?
    public var containerExtension: String
    public var tmdbID: String?
    public var categoryID: String?

    public init(streamID: String, title: String, year: Int? = nil, posterURL: URL? = nil,
                rating: Double? = nil, plot: String? = nil, containerExtension: String = "mp4",
                tmdbID: String? = nil, categoryID: String? = nil) {
        self.streamID = streamID
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.rating = rating
        self.plot = plot
        self.containerExtension = containerExtension
        self.tmdbID = tmdbID
        self.categoryID = categoryID
    }
}

public struct ParsedSeries: Sendable, Equatable {
    public var seriesID: String
    public var title: String
    public var posterURL: URL?
    public var plot: String?
    public var categoryID: String?

    public init(seriesID: String, title: String, posterURL: URL? = nil,
                plot: String? = nil, categoryID: String? = nil) {
        self.seriesID = seriesID
        self.title = title
        self.posterURL = posterURL
        self.plot = plot
        self.categoryID = categoryID
    }
}

public struct ParsedEpisode: Sendable, Equatable {
    public var episodeID: String
    public var season: Int
    public var number: Int
    public var title: String
    public var containerExtension: String
    public var plot: String?
    public var durationSeconds: Int?

    public init(episodeID: String, season: Int, number: Int, title: String,
                containerExtension: String = "mp4", plot: String? = nil,
                durationSeconds: Int? = nil) {
        self.episodeID = episodeID
        self.season = season
        self.number = number
        self.title = title
        self.containerExtension = containerExtension
        self.plot = plot
        self.durationSeconds = durationSeconds
    }
}

public struct Category: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var parentID: String?

    public init(id: String, name: String, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}
