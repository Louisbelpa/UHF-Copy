import Foundation
import UHFCore
import UHFSources
import UHFStore

/// Orchestration d'un rafraîchissement de source, de bout en bout.
///
/// C'est ici que les briques se rejoignent : téléchargement, analyse, écriture en
/// base, appariement au guide, purge. L'interface n'a qu'un appel à faire, et reçoit
/// la progression au fil de l'eau.
public actor PlaylistSyncService {

    // MARK: - Progression et bilan

    public enum Phase: Sendable, Equatable {
        case connecting
        case downloadingPlaylist(Double?)
        case importingChannels(Int)
        case importingCatalogue
        case downloadingEPG(Double?)
        case importingEPG(Int)
        case matchingEPG
        case finishing

        public var label: String {
            switch self {
            case .connecting: "Connexion au serveur…"
            case .downloadingPlaylist(let fraction):
                fraction.map { "Téléchargement de la playlist… \(Int($0 * 100)) %" }
                    ?? "Téléchargement de la playlist…"
            case .importingChannels(let count): "Import des chaînes… \(count)"
            case .importingCatalogue: "Import des films et séries…"
            case .downloadingEPG(let fraction):
                fraction.map { "Téléchargement du guide… \(Int($0 * 100)) %" }
                    ?? "Téléchargement du guide…"
            case .importingEPG(let count): "Import du guide… \(count) programmes"
            case .matchingEPG: "Association des chaînes au guide…"
            case .finishing: "Finalisation…"
            }
        }
    }

    public struct Report: Sendable {
        public var playlistID: String
        public var channels: MergeReport
        public var movies: MergeReport?
        public var series: MergeReport?
        public var epg: MergeReport?
        /// Part des chaînes rattachées à une entrée du guide.
        public var epgMatchRate: Double?
        /// Anomalies non bloquantes, à présenter dans l'écran de diagnostic.
        public var warnings: [String] = []
        public var duration: TimeInterval = 0

        /// Un import dont le guide n'est associé qu'à une minorité de chaînes mérite
        /// de pousser l'utilisateur vers l'écran de correspondance manuelle.
        public var suggestsManualEPGMapping: Bool {
            guard let rate = epgMatchRate else { return false }
            return rate < 0.8
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unsupportedKind(PlaylistKind)
        case missingCredentials
        case emptyPlaylist
        case suspiciousResult(previous: Int, new: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedKind(let kind):
                "Ce type de source n'est pas encore pris en charge : \(kind.rawValue)."
            case .missingCredentials:
                "Identifiants introuvables pour cette source."
            case .emptyPlaylist:
                "La source n'a renvoyé aucune chaîne."
            case .suspiciousResult(let previous, let new):
                """
                La source n'a renvoyé que \(new) chaînes contre \(previous) au dernier \
                rafraîchissement. L'import a été annulé pour ne pas effacer votre \
                catalogue — réessayez plus tard.
                """
            }
        }
    }

    // MARK: - Dépendances

    private let database: UHFDatabase
    private let downloader: any FileDownloading
    private let transport: any HTTPTransport
    /// Fournit les identifiants Xtream, qui vivent dans le Keychain et non en base.
    private let credentialsProvider: @Sendable (String) -> (username: String, password: String)?

    public init(database: UHFDatabase,
                downloader: any FileDownloading = URLSessionDownloader.makeDefault(),
                transport: any HTTPTransport = URLSessionTransport.makeDefault(),
                credentialsProvider: @escaping @Sendable (String) -> (username: String, password: String)? = { _ in nil }) {
        self.database = database
        self.downloader = downloader
        self.transport = transport
        self.credentialsProvider = credentialsProvider
    }

    // MARK: - Point d'entrée

    /// Rafraîchit une source complète.
    ///
    /// - Parameter refuseSuspiciousResults: annule l'import si la source renvoie
    ///   soudain une fraction du catalogue précédent. Un serveur surchargé répond
    ///   souvent une playlist tronquée avec un code 200 : l'appliquer effacerait les
    ///   chaînes de l'utilisateur pour une panne passagère.
    @discardableResult
    public func refresh(playlist: PlaylistRecord,
                        refuseSuspiciousResults: Bool = true,
                        onProgress: @Sendable @escaping (Phase) -> Void = { _ in }) async throws -> Report {
        let startedAt = Date()
        onProgress(.connecting)

        var report: Report
        switch playlist.playlistKind {
        case .m3u:
            report = try await refreshM3U(playlist, onProgress: onProgress)
        case .xtream:
            report = try await refreshXtream(playlist, onProgress: onProgress)
        case .some(let kind):
            throw Failure.unsupportedKind(kind)
        case nil:
            throw Failure.unsupportedKind(.m3u)
        }

        if refuseSuspiciousResults, report.channels.looksSuspicious {
            // Le catalogue précédent a déjà été écrasé par la session d'import ; on
            // ne peut plus que prévenir, d'où le contrôle en amont côté Xtream.
            report.warnings.append(Failure.suspiciousResult(
                previous: report.channels.previousTotal,
                new: report.channels.total).localizedDescription)
        }

        // Guide : facultatif, et son échec ne doit jamais faire échouer l'import des
        // chaînes — regarder la télévision sans guide reste possible.
        if let epgURL = epgURL(for: playlist) {
            do {
                report.epg = try await refreshEPG(playlist, url: epgURL, onProgress: onProgress)
                onProgress(.matchingEPG)
                report.epgMatchRate = try matchChannelsToEPG(playlistID: playlist.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.warnings.append("Guide indisponible : \(error.localizedDescription)")
            }
        }

        onProgress(.finishing)
        try EPGStore(database).purge(before: EPGStore.retentionWindow().lowerBound)

        report.duration = Date().timeIntervalSince(startedAt)
        return report
    }

    // MARK: - M3U

    private func refreshM3U(_ playlist: PlaylistRecord,
                            onProgress: @Sendable @escaping (Phase) -> Void) async throws -> Report {
        guard let url = URL(string: playlist.url) else { throw Failure.emptyPlaylist }

        onProgress(.downloadingPlaylist(nil))
        let file = try await downloader.download(from: url,
                                                 headers: headers(for: playlist),
                                                 progress: { onProgress(.downloadingPlaylist($0)) })
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()

        let store = ChannelStore(database)
        let session = try store.beginImport(playlistID: playlist.id)
        var count = 0
        var declaredEPG: [URL] = []

        let result = try M3UParser.parse(fileAt: file, isCancelled: { Task.isCancelled }) { channel in
            try session.append(channel)
            count += 1
            // Un rapport tous les mille : au-delà, c'est l'interface qu'on sature.
            if count % 1_000 == 0 { onProgress(.importingChannels(count)) }
        }
        try Task.checkCancellation()
        declaredEPG = result.header.epgURLs

        let merge = try session.finish()
        guard merge.total > 0 else { throw Failure.emptyPlaylist }

        // La playlist déclare souvent son propre guide : on le retient pour les
        // rafraîchissements suivants.
        if playlist.epgURL == nil, let first = declaredEPG.first {
            // En contexte asynchrone, GRDB expose une variante `async` de `write` :
            // c'est celle qu'il faut, elle ne bloque pas l'exécuteur de l'acteur.
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE playlists SET epgURL = ? WHERE id = ?",
                               arguments: [first.absoluteString, playlist.id])
            }
        }

        var report = Report(playlistID: playlist.id, channels: merge)
        if !result.skipped.isEmpty {
            report.warnings.append("\(result.skipped.count) ligne(s) ignorée(s) dans la playlist.")
        }
        return report
    }

    // MARK: - Xtream

    private func refreshXtream(_ playlist: PlaylistRecord,
                               onProgress: @Sendable @escaping (Phase) -> Void) async throws -> Report {
        guard let baseURL = URL(string: playlist.url),
              let credentials = credentialsProvider(playlist.credentialsRef ?? playlist.id)
        else { throw Failure.missingCredentials }

        let client = XtreamClient(
            credentials: .init(baseURL: baseURL,
                               username: credentials.username,
                               password: credentials.password),
            transport: transport,
            userAgent: playlist.userAgent)

        // Valider le compte avant tout : inutile de télécharger 80 000 chaînes pour
        // découvrir ensuite que l'abonnement a expiré.
        let account = try await client.account()
        try Task.checkCancellation()

        onProgress(.downloadingPlaylist(nil))
        let channels = try await client.liveChannels(format: account.preferredLiveFormat)
        guard !channels.isEmpty else { throw Failure.emptyPlaylist }

        let store = ChannelStore(database)
        let previous = try store.count(playlistID: playlist.id)
        // Contrôle **avant** écriture : contrairement au M3U lu en flux, on a ici tout
        // le catalogue en main et on peut encore refuser de l'appliquer.
        let candidate = MergeReport(added: channels.count, previousTotal: previous)
        if candidate.looksSuspicious {
            throw Failure.suspiciousResult(previous: previous, new: channels.count)
        }

        onProgress(.importingChannels(channels.count))
        var report = Report(playlistID: playlist.id,
                            channels: try store.merge(channels, playlistID: playlist.id))

        if let limit = account.maxConnections, limit <= 1 {
            report.warnings.append(
                "Votre abonnement n'autorise qu'une connexion : la lecture sur un autre appareil coupera celle-ci.")
        }
        if let expiry = account.expiresAt, expiry.timeIntervalSinceNow < 7 * 86_400 {
            report.warnings.append(
                "Votre abonnement expire le \(expiry.formatted(date: .abbreviated, time: .omitted)).")
        }

        // Films et séries : leur échec ne doit pas compromettre les chaînes, qui sont
        // l'essentiel de l'usage.
        onProgress(.importingCatalogue)
        let vod = VODStore(database)
        do {
            report.movies = try vod.merge(movies: try await client.movies(), playlistID: playlist.id)
        } catch {
            report.warnings.append("Films indisponibles : \(error.localizedDescription)")
        }
        do {
            report.series = try vod.merge(series: try await client.series(), playlistID: playlist.id)
        } catch {
            report.warnings.append("Séries indisponibles : \(error.localizedDescription)")
        }
        return report
    }

    // MARK: - Guide

    private func refreshEPG(_ playlist: PlaylistRecord,
                            url: URL,
                            onProgress: @Sendable @escaping (Phase) -> Void) async throws -> MergeReport {
        onProgress(.downloadingEPG(nil))
        let file = try await downloader.download(from: url,
                                                 headers: headers(for: playlist),
                                                 progress: { onProgress(.downloadingEPG($0)) })
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()

        let store = EPGStore(database)
        let session = try store.beginImport(playlistID: playlist.id)
        var count = 0
        var importFailure: Error?

        let parser = XMLTVParser(
            options: .init(preferredLanguages: Self.preferredLanguages,
                           window: EPGStore.retentionWindow()),
            isCancelled: { Task.isCancelled },
            onChannel: { channel in
                do { try session.append(channel: channel) } catch { importFailure = error }
            },
            onProgramme: { programme in
                do {
                    try session.append(programme: programme)
                    count += 1
                    if count % 20_000 == 0 { onProgress(.importingEPG(count)) }
                } catch { importFailure = error }
            })

        _ = try parser.parse(fileAt: file)
        if let importFailure { throw importFailure }
        return try session.finish()
    }

    /// Rapproche les chaînes du guide et enregistre les correspondances.
    /// - Returns: la part de chaînes rattachées.
    private func matchChannelsToEPG(playlistID: String) throws -> Double {
        let channelStore = ChannelStore(database)
        let epgStore = EPGStore(database)

        let epgChannels = try epgStore.epgChannels(playlistID: playlistID)
        guard !epgChannels.isEmpty else { return 0 }
        let matcher = EPGMatcher(epgChannels: epgChannels)

        var matched = 0
        var total = 0
        var page = 0
        let pageSize = 2_000

        // Par pages : une playlist de 150 000 chaînes ne tient pas en mémoire d'un bloc.
        while true {
            let records = try channelStore.channels(playlistID: playlistID,
                                                    includeAdult: true,
                                                    limit: pageSize,
                                                    offset: page * pageSize)
            if records.isEmpty { break }

            var links: [(channelKey: StableKey, xmltvID: String, confidence: Int)] = []
            for record in records {
                total += 1
                guard let parsed = record.parsedChannel(),
                      let match = matcher.match(parsed) else { continue }
                matched += 1
                links.append((record.stableKey, match.xmltvID, match.confidence.rawValue))
            }
            try epgStore.saveLinks(links, playlistID: playlistID)

            if records.count < pageSize { break }
            page += 1
        }
        return total == 0 ? 0 : Double(matched) / Double(total)
    }

    // MARK: - Détails

    private func epgURL(for playlist: PlaylistRecord) -> URL? {
        if let declared = playlist.epgURL, let url = URL(string: declared) { return url }
        // Le guide déclaré par la playlist a pu être enregistré à l'instant même,
        // pendant l'import des chaînes : on relit donc la ligne plutôt que l'objet reçu.
        // `try?` aplatit l'optionnel du retour : `stored` est bien une `String`.
        guard let stored = try? storedEPGURL(playlistID: playlist.id) else { return nil }
        return URL(string: stored)
    }

    private func storedEPGURL(playlistID: String) throws -> String? {
        try database.reader.read { db in
            try PlaylistRecord.fetchOne(db, key: playlistID)?.epgURL
        }
    }

    private func headers(for playlist: PlaylistRecord) -> [String: String] {
        var headers: [String: String] = [:]
        if let userAgent = playlist.userAgent { headers["User-Agent"] = userAgent }
        if let referer = playlist.referer { headers["Referer"] = referer }
        return headers
    }

    private static var preferredLanguages: [String] {
        Locale.preferredLanguages.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        }
    }
}
