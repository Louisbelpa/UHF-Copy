import Foundation
import UHFCore

public enum XtreamError: Error, LocalizedError, Equatable {
    case invalidCredentials
    case accountExpired(Date?)
    case accountDisabled(String?)
    case maxConnectionsReached(Int?)
    case http(Int)
    case malformedResponse(String)

    /// Messages destinés à l'utilisateur, pas au développeur : « erreur -1009 » n'a
    /// jamais aidé personne à comprendre que son abonnement avait expiré.
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Identifiants refusés par le serveur. Vérifiez l'adresse, le nom d'utilisateur et le mot de passe."
        case .accountExpired(let date):
            if let date {
                "Abonnement expiré le \(date.formatted(date: .abbreviated, time: .omitted))."
            } else {
                "Abonnement expiré."
            }
        case .accountDisabled(let status):
            "Compte inactif\(status.map { " (\($0))" } ?? "")."
        case .maxConnectionsReached(let limit):
            if let limit {
                "Nombre maximum de connexions simultanées atteint (\(limit)). Fermez un autre appareil."
            } else {
                "Nombre maximum de connexions simultanées atteint."
            }
        case .http(let code):
            "Le serveur a répondu \(code)."
        case .malformedResponse(let detail):
            "Réponse du serveur incompréhensible : \(detail)"
        }
    }
}

/// Format de sortie demandé au serveur pour les flux live.
public enum XtreamOutputFormat: String, Sendable, CaseIterable {
    /// HLS : lisible par AVPlayer, donc PiP, AirPlay, HDR et Atmos. À privilégier.
    case m3u8
    /// MPEG-TS brut : format par défaut de la plupart des panneaux, **illisible par
    /// AVPlayer**, nécessite le moteur VLCKit.
    case ts
}

public struct XtreamAccount: Sendable, Equatable {
    public var username: String
    public var isAuthenticated: Bool
    public var status: String?
    public var expiresAt: Date?
    public var isTrial: Bool
    public var activeConnections: Int?
    public var maxConnections: Int?
    public var allowedOutputFormats: [XtreamOutputFormat]
    public var serverTimezone: String?
    public var serverTime: Date?

    /// Le format à utiliser pour les flux live : HLS dès que le serveur le propose,
    /// afin de rester sur AVPlayer et de conserver PiP/AirPlay/HDR.
    public var preferredLiveFormat: XtreamOutputFormat {
        allowedOutputFormats.contains(.m3u8) ? .m3u8 : .ts
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }
}

extension XtreamAccount: Decodable {
    private enum RootKeys: String, CodingKey { case user_info, server_info }
    private enum UserKeys: String, CodingKey {
        case username, auth, status, exp_date, is_trial, active_cons, max_connections
        case allowed_output_formats, message
    }
    private enum ServerKeys: String, CodingKey { case timezone, timestamp_now }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        guard let user = try? root.nestedContainer(keyedBy: UserKeys.self, forKey: .user_info) else {
            throw XtreamError.malformedResponse("bloc user_info absent")
        }
        username = user.lenientString(.username) ?? ""
        isAuthenticated = user.lenientBool(.auth) ?? false
        status = user.lenientString(.status)
        expiresAt = user.lenientEpochDate(.exp_date)
        isTrial = user.lenientBool(.is_trial) ?? false
        activeConnections = user.lenientInt(.active_cons)
        maxConnections = user.lenientInt(.max_connections)

        let formats = (try? user.decodeIfPresent([String].self, forKey: .allowed_output_formats)) ?? []
        allowedOutputFormats = formats.compactMap { XtreamOutputFormat(rawValue: $0.lowercased()) }

        let server = try? root.nestedContainer(keyedBy: ServerKeys.self, forKey: .server_info)
        serverTimezone = server?.lenientString(.timezone)
        serverTime = server?.lenientEpochDate(.timestamp_now)
    }
}

// MARK: - Éléments de catalogue

struct XtreamCategoryDTO: Decodable {
    let id: String
    let name: String
    let parentID: String?

    private enum Keys: String, CodingKey { case category_id, category_name, parent_id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lenientString(.category_id) else {
            throw XtreamError.malformedResponse("catégorie sans identifiant")
        }
        self.id = id
        self.name = c.lenientString(.category_name) ?? "Sans nom"
        let parent = c.lenientString(.parent_id)
        self.parentID = (parent == "0") ? nil : parent
    }

    var model: Category { Category(id: id, name: name, parentID: parentID) }
}

struct XtreamLiveStreamDTO: Decodable {
    let streamID: String
    let name: String
    let icon: URL?
    let epgChannelID: String?
    let categoryID: String?
    let hasArchive: Bool
    let archiveDays: Int?
    let number: Int?
    /// Certains panneaux imposent une URL de flux différente de la forme canonique.
    let directSource: URL?

    private enum Keys: String, CodingKey {
        case stream_id, name, stream_icon, epg_channel_id, category_id
        case tv_archive, tv_archive_duration, num, direct_source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lenientString(.stream_id) else {
            throw XtreamError.malformedResponse("flux sans stream_id")
        }
        streamID = id
        name = c.lenientString(.name) ?? "Sans nom"
        icon = c.lenientURL(.stream_icon)
        epgChannelID = c.lenientString(.epg_channel_id)
        categoryID = c.lenientString(.category_id)
        hasArchive = c.lenientBool(.tv_archive) ?? false
        archiveDays = c.lenientInt(.tv_archive_duration)
        number = c.lenientInt(.num)
        directSource = c.lenientURL(.direct_source)
    }
}

struct XtreamVODStreamDTO: Decodable {
    let streamID: String
    let name: String
    let icon: URL?
    let rating: Double?
    let categoryID: String?
    let containerExtension: String

    private enum Keys: String, CodingKey {
        case stream_id, name, stream_icon, rating, category_id, container_extension
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lenientString(.stream_id) else {
            throw XtreamError.malformedResponse("film sans stream_id")
        }
        streamID = id
        name = c.lenientString(.name) ?? "Sans titre"
        icon = c.lenientURL(.stream_icon)
        rating = c.lenientDouble(.rating)
        categoryID = c.lenientString(.category_id)
        containerExtension = c.lenientString(.container_extension) ?? "mp4"
    }

    var model: ParsedMovie {
        let (title, year) = extractYear(from: name)
        return ParsedMovie(streamID: streamID, title: title, year: year, posterURL: icon,
                           rating: rating, containerExtension: containerExtension,
                           categoryID: categoryID)
    }
}

struct XtreamSeriesDTO: Decodable {
    let seriesID: String
    let name: String
    let cover: URL?
    let plot: String?
    let categoryID: String?

    private enum Keys: String, CodingKey { case series_id, name, cover, plot, category_id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lenientString(.series_id) else {
            throw XtreamError.malformedResponse("série sans series_id")
        }
        seriesID = id
        name = c.lenientString(.name) ?? "Sans titre"
        cover = c.lenientURL(.cover)
        plot = c.lenientString(.plot)
        categoryID = c.lenientString(.category_id)
    }

    var model: ParsedSeries {
        ParsedSeries(seriesID: seriesID, title: name, posterURL: cover,
                     plot: plot, categoryID: categoryID)
    }
}

/// `get_series_info` : les épisodes arrivent dans un dictionnaire dont les clés sont
/// les numéros de saison **en chaînes de caractères**, pas dans un tableau.
struct XtreamSeriesInfoDTO: Decodable {
    let episodes: [ParsedEpisode]

    private enum Keys: String, CodingKey { case episodes }
    private struct EpisodeDTO: Decodable {
        let id: String
        let season: Int?
        let episodeNumber: Int?
        let title: String
        let containerExtension: String
        let durationSeconds: Int?
        let plot: String?

        private enum Keys: String, CodingKey {
            case id, season, episode_num, title, container_extension, info
        }
        private enum InfoKeys: String, CodingKey { case duration_secs, plot, movie_image }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            guard let id = c.lenientString(.id) else {
                throw XtreamError.malformedResponse("épisode sans identifiant")
            }
            self.id = id
            season = c.lenientInt(.season)
            episodeNumber = c.lenientInt(.episode_num)
            title = c.lenientString(.title) ?? "Épisode"
            containerExtension = c.lenientString(.container_extension) ?? "mp4"
            let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info)
            durationSeconds = info?.lenientInt(.duration_secs)
            plot = info?.lenientString(.plot)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let bySeason = (try? c.decodeIfPresent([String: [EpisodeDTO]].self, forKey: .episodes)) ?? [:]

        episodes = bySeason
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            .flatMap { seasonKey, list in
                list.map { dto in
                    ParsedEpisode(
                        episodeID: dto.id,
                        // La clé du dictionnaire fait autorité : le champ `season` de
                        // l'épisode est parfois à 0 sur les panneaux mal alimentés.
                        season: dto.season.flatMap { $0 > 0 ? $0 : nil } ?? Int(seasonKey) ?? 1,
                        number: dto.episodeNumber ?? 0,
                        title: dto.title,
                        containerExtension: dto.containerExtension,
                        plot: dto.plot,
                        durationSeconds: dto.durationSeconds)
                }
            }
            .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }
}

/// `get_short_epg` : titres et descriptions encodés en base64 sur la majorité des panneaux.
struct XtreamShortEPGDTO: Decodable {
    let listings: [EPGProgramme]

    private enum Keys: String, CodingKey { case epg_listings }
    private struct ListingDTO: Decodable {
        let channelID: String
        let start: Date?
        let stop: Date?
        let title: String
        let description: String?

        private enum Keys: String, CodingKey {
            case channel_id, start_timestamp, stop_timestamp, title, description
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            channelID = c.lenientString(.channel_id) ?? ""
            start = c.lenientEpochDate(.start_timestamp)
            stop = c.lenientEpochDate(.stop_timestamp)
            title = c.lenientMaybeBase64String(.title) ?? ""
            description = c.lenientMaybeBase64String(.description)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let raw = (try? c.decodeIfPresent([ListingDTO].self, forKey: .epg_listings)) ?? []
        listings = raw.compactMap { dto in
            guard let start = dto.start, let stop = dto.stop else { return nil }
            return EPGProgramme(channelID: dto.channelID, start: start, stop: stop,
                                title: dto.title, desc: dto.description)
        }
    }
}
