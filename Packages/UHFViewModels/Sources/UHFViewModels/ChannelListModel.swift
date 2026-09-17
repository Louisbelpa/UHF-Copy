import Foundation
import Observation
import UHFCore
import UHFStore

/// État de la liste de chaînes : pagination, filtres, enrichissement par le guide.
///
/// Toute la difficulté tient en une phrase : une playlist fait 150 000 chaînes, et le
/// guide ne doit être interrogé que pour celles réellement affichées à l'écran.
@MainActor
@Observable
public final class ChannelListModel {

    public struct Row: Identifiable, Sendable, Equatable {
        public var channel: ChannelRecord
        public var override: ChannelOverrideRecord?
        public var now: ProgrammeRecord?
        public var next: ProgrammeRecord?
        public var isFavorite: Bool

        public var id: String { channel.key }
        public var key: StableKey { channel.stableKey }
        public var displayName: String { override?.customName ?? channel.name }
        public var logoURL: URL? {
            (override?.customLogoURL ?? channel.logoURL).flatMap(URL.init(string:))
        }
        /// Avancement du programme en cours, pour la barre de progression.
        public func progress(at date: Date = Date()) -> Double? {
            now?.progress(at: date)
        }
    }

    public enum Filter: Sendable, Equatable {
        case all
        case group(String)
        case favorites
    }

    // MARK: - État observable

    public private(set) var rows: [Row] = []
    public private(set) var groups: [ChannelStore.ChannelGroup] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = true
    public private(set) var errorMessage: String?

    public var filter: Filter = .all {
        didSet { if filter != oldValue { reloadFromScratch() } }
    }
    public var includeAdult = false {
        didSet { if includeAdult != oldValue { reloadFromScratch() } }
    }

    // MARK: - Dépendances

    private let channels: ChannelStore
    private let epg: EPGStore
    private let library: LibraryStore
    private let playlistID: String
    private let pageSize: Int
    private var page = 0

    public init(database: UHFDatabase, playlistID: String, pageSize: Int = 100) {
        self.channels = ChannelStore(database)
        self.epg = EPGStore(database)
        self.library = LibraryStore(database)
        self.playlistID = playlistID
        self.pageSize = pageSize
    }

    // MARK: - Chargement

    public func loadGroups() {
        do {
            groups = try channels.groups(playlistID: playlistID, includeAdult: includeAdult)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func reloadFromScratch() {
        page = 0
        rows = []
        hasMore = true
        errorMessage = nil
        loadNextPage()
    }

    /// Charge la page suivante. Appelé quand l'utilisateur approche du bas de la liste.
    public func loadNextPage() {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try fetchPage()
            hasMore = fetched.count == pageSize && filter != .favorites
            page += 1
            rows += try decorate(fetched)
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    private func fetchPage() throws -> [ChannelRecord] {
        switch filter {
        case .all:
            return try channels.channels(playlistID: playlistID, includeAdult: includeAdult,
                                         limit: pageSize, offset: page * pageSize)
        case .group(let name):
            return try channels.channels(playlistID: playlistID, group: name,
                                         includeAdult: includeAdult,
                                         limit: pageSize, offset: page * pageSize)
        case .favorites:
            // Les favoris tiennent en une page par construction : on les charge d'un bloc.
            return page == 0 ? try library.favoriteChannels() : []
        }
    }

    /// Enrichit une page avec le guide, les personnalisations et les favoris.
    ///
    /// Trois requêtes pour cent lignes, et non trois cents : c'est ce qui permet au
    /// défilement de tenir 60 images par seconde.
    private func decorate(_ records: [ChannelRecord]) throws -> [Row] {
        let keys = records.map(\.stableKey)
        let guide = try epg.nowNext(channelKeys: keys, playlistID: playlistID)
        let overrides = try library.overrides(for: keys)
        let favorites = try favoriteKeys()

        return records.map { record in
            Row(channel: record,
                override: overrides[record.key],
                now: guide[record.stableKey]?.current,
                next: guide[record.stableKey]?.next,
                isFavorite: favorites.contains(record.key))
        }
    }

    private func favoriteKeys() throws -> Set<String> {
        Set(try library.favoriteChannels().map(\.key))
    }

    // MARK: - Actions

    public func toggleFavorite(_ row: Row) {
        do {
            try library.setFavorite(!row.isFavorite, key: row.key, kind: .channel)
            // Mise à jour locale plutôt que rechargement : l'étoile doit répondre
            // instantanément, même avec 150 000 chaînes derrière.
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index].isFavorite.toggle()
            }
            if filter == .favorites { reloadFromScratch() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func rename(_ row: Row, to name: String?) {
        do {
            let trimmed = name?.trimmingCharacters(in: .whitespaces)
            var override = try library.override(for: row.key)
                ?? ChannelOverrideRecord(channelKey: row.key)
            // Un nom vide ou identique à celui de la source annule le renommage plutôt
            // que d'enregistrer un doublon inutile.
            override.customName = (trimmed?.isEmpty == false && trimmed != row.channel.name)
                ? trimmed : nil
            try library.setOverride(override)

            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index].override = try library.override(for: row.key)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func hide(_ row: Row) {
        do {
            var override = try library.override(for: row.key)
                ?? ChannelOverrideRecord(channelKey: row.key)
            override.isHidden = true
            try library.setOverride(override)
            rows.removeAll { $0.id == row.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rafraîchit uniquement le guide des lignes déjà affichées.
    /// À appeler au retour au premier plan et au changement d'heure — sans recharger
    /// la liste, qui n'a pas bougé.
    public func refreshGuide(at date: Date = Date()) {
        guard !rows.isEmpty else { return }
        do {
            let guide = try epg.nowNext(channelKeys: rows.map(\.key),
                                        playlistID: playlistID, at: date)
            for index in rows.indices {
                rows[index].now = guide[rows[index].key]?.current
                rows[index].next = guide[rows[index].key]?.next
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func dismissError() { errorMessage = nil }
}
