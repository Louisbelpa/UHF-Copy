import Foundation
import UHFCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client de l'API Xtream Codes (`player_api.php`).
///
/// Volontairement sans état : c'est la couche d'import qui décide quoi persister.
public struct XtreamClient: Sendable {

    public struct Credentials: Sendable, Equatable {
        public var baseURL: URL
        public var username: String
        public var password: String

        public init(baseURL: URL, username: String, password: String) {
            self.baseURL = baseURL
            self.username = username
            self.password = password
        }

        /// Accepte ce que l'utilisateur colle réellement : une URL complète de playlist
        /// (`http://srv:80/get.php?username=u&password=p&type=m3u_plus`) aussi bien
        /// qu'une simple adresse de serveur. Le champ « URL » est la première source
        /// d'échec à la configuration.
        public init?(pastedURL raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
            guard var components = URLComponents(string: withScheme), components.host != nil else {
                return nil
            }
            let query = components.queryItems ?? []
            let user = query.first { $0.name == "username" }?.value
            let pass = query.first { $0.name == "password" }?.value

            components.query = nil
            components.path = ""
            components.fragment = nil
            guard let base = components.url, let user, let pass else { return nil }
            self.init(baseURL: base, username: user, password: pass)
        }
    }

    private let credentials: Credentials
    private let transport: HTTPTransport
    private let userAgent: String?

    public init(credentials: Credentials,
                transport: HTTPTransport = URLSessionTransport.makeDefault(),
                userAgent: String? = nil) {
        self.credentials = credentials
        self.transport = transport
        self.userAgent = userAgent
    }

    // MARK: - Appels

    /// Vérifie les identifiants et renseigne les capacités du serveur.
    /// À appeler **avant** tout import : inutile de télécharger 80 000 chaînes pour
    /// découvrir ensuite que l'abonnement a expiré.
    public func account() async throws -> XtreamAccount {
        let account: XtreamAccount = try await get(action: nil)
        guard account.isAuthenticated else { throw XtreamError.invalidCredentials }
        if account.isExpired { throw XtreamError.accountExpired(account.expiresAt) }
        if let status = account.status, !["active", "enabled"].contains(status.lowercased()) {
            throw XtreamError.accountDisabled(status)
        }
        return account
    }

    public func liveCategories() async throws -> [Category] {
        let dtos: [XtreamCategoryDTO] = try await get(action: "get_live_categories")
        return dtos.map(\.model)
    }

    public func vodCategories() async throws -> [Category] {
        let dtos: [XtreamCategoryDTO] = try await get(action: "get_vod_categories")
        return dtos.map(\.model)
    }

    public func seriesCategories() async throws -> [Category] {
        let dtos: [XtreamCategoryDTO] = try await get(action: "get_series_categories")
        return dtos.map(\.model)
    }

    /// Chaînes live, déjà converties en ``ParsedChannel`` avec leur URL de lecture.
    public func liveChannels(categoryID: String? = nil,
                             format: XtreamOutputFormat) async throws -> [ParsedChannel] {
        var query: [URLQueryItem] = []
        if let categoryID { query.append(URLQueryItem(name: "category_id", value: categoryID)) }
        let dtos: [XtreamLiveStreamDTO] = try await get(action: "get_live_streams", query: query)

        return dtos.enumerated().map { index, dto in
            ParsedChannel(
                name: dto.name,
                url: dto.directSource ?? liveURL(streamID: dto.streamID, format: format),
                streamID: dto.streamID,
                logoURL: dto.icon,
                groupTitle: dto.categoryID,
                tvgID: dto.epgChannelID,
                tvgName: dto.name,
                catchup: dto.hasArchive ? .xtream : nil,
                catchupDays: dto.hasArchive ? dto.archiveDays : nil,
                sortIndex: dto.number ?? index)
        }
    }

    public func movies(categoryID: String? = nil) async throws -> [ParsedMovie] {
        var query: [URLQueryItem] = []
        if let categoryID { query.append(URLQueryItem(name: "category_id", value: categoryID)) }
        let dtos: [XtreamVODStreamDTO] = try await get(action: "get_vod_streams", query: query)
        return dtos.map(\.model)
    }

    public func series(categoryID: String? = nil) async throws -> [ParsedSeries] {
        var query: [URLQueryItem] = []
        if let categoryID { query.append(URLQueryItem(name: "category_id", value: categoryID)) }
        let dtos: [XtreamSeriesDTO] = try await get(action: "get_series", query: query)
        return dtos.map(\.model)
    }

    public func episodes(seriesID: String) async throws -> [ParsedEpisode] {
        let info: XtreamSeriesInfoDTO = try await get(
            action: "get_series_info",
            query: [URLQueryItem(name: "series_id", value: seriesID)])
        return info.episodes
    }

    /// EPG « now / next » d'une chaîne. Utile pour remplir la liste sans attendre
    /// l'import XMLTV complet.
    public func shortEPG(streamID: String, limit: Int = 8) async throws -> [EPGProgramme] {
        let dto: XtreamShortEPGDTO = try await get(
            action: "get_short_epg",
            query: [URLQueryItem(name: "stream_id", value: streamID),
                    URLQueryItem(name: "limit", value: String(limit))])
        return dto.listings
    }

    // MARK: - URLs de lecture

    public func liveURL(streamID: String, format: XtreamOutputFormat) -> URL {
        streamURL(kind: "live", identifier: streamID, extension: format.rawValue)
    }

    public func movieURL(streamID: String, containerExtension: String) -> URL {
        streamURL(kind: "movie", identifier: streamID, extension: containerExtension)
    }

    public func episodeURL(episodeID: String, containerExtension: String) -> URL {
        streamURL(kind: "series", identifier: episodeID, extension: containerExtension)
    }

    private func streamURL(kind: String, identifier: String, extension ext: String) -> URL {
        credentials.baseURL
            .appendingPathComponent(kind)
            .appendingPathComponent(credentials.username)
            .appendingPathComponent(credentials.password)
            .appendingPathComponent("\(identifier).\(ext)")
    }

    /// URL du XMLTV complet servi par le panneau.
    public var epgURL: URL {
        var components = URLComponents(url: credentials.baseURL.appendingPathComponent("xmltv.php"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = authQuery
        return components.url!
    }

    /// Replay Xtream : `streaming/timeshift.php`.
    public func timeshiftURL(streamID: String, start: Date, duration: TimeInterval) -> URL {
        var components = URLComponents(
            url: credentials.baseURL.appendingPathComponent("streaming/timeshift.php"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = authQuery + [
            URLQueryItem(name: "stream", value: streamID),
            URLQueryItem(name: "start", value: CatchupURLBuilder.xtreamTimestamp(start)),
            URLQueryItem(name: "duration", value: String(Int(duration / 60))),
        ]
        return components.url!
    }

    // MARK: - Transport

    private var authQuery: [URLQueryItem] {
        [URLQueryItem(name: "username", value: credentials.username),
         URLQueryItem(name: "password", value: credentials.password)]
    }

    func endpoint(action: String?, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: credentials.baseURL.appendingPathComponent("player_api.php"),
            resolvingAgainstBaseURL: false)!
        var items = authQuery
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        components.queryItems = items + query
        return components.url!
    }

    private func get<T: Decodable>(action: String?, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: endpoint(action: action, query: query))
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)

        switch response.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw XtreamError.invalidCredentials
        case 456, 509:
            // Codes employés par certains panneaux pour la limite de connexions.
            throw XtreamError.maxConnectionsReached(nil)
        default:
            throw XtreamError.http(response.statusCode)
        }

        // Un panneau qui refuse les identifiants répond souvent 200 avec un corps vide,
        // `[]`, ou `{"user_info":{"auth":0}}` — jamais un code d'erreur HTTP.
        if data.isEmpty { throw XtreamError.malformedResponse("corps vide") }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if let text = String(data: data.prefix(200), encoding: .utf8),
               text.lowercased().contains("auth") || text.contains("\"auth\":0") {
                throw XtreamError.invalidCredentials
            }
            throw XtreamError.malformedResponse(String(describing: error).prefix(200).description)
        }
    }
}
