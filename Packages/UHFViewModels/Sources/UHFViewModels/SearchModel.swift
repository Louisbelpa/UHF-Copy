import Foundation
import Observation
import UHFCore
import UHFStore

/// Recherche instantanée.
///
/// Deux règles suffisent à la rendre agréable, et leur absence à la rendre
/// inutilisable : ne rien chercher en dessous de deux caractères, et attendre que la
/// frappe se calme. Sans elles, taper « beIN » déclenche quatre requêtes dont trois
/// jetées, et la première — sur une seule lettre — apparie tout le catalogue.
@MainActor
@Observable
public final class SearchModel {

    public private(set) var results: [ChannelListModel.Row] = []
    public private(set) var isSearching = false
    public private(set) var errorMessage: String?

    public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    /// En deçà, la recherche ne se déclenche pas.
    public let minimumLength: Int
    /// Délai d'inactivité avant de lancer la requête.
    public let debounce: Duration

    private let channels: ChannelStore
    private let epg: EPGStore
    private let library: LibraryStore
    private let playlistID: String?
    private var task: Task<Void, Never>?

    public init(database: UHFDatabase,
                playlistID: String? = nil,
                minimumLength: Int = 2,
                debounce: Duration = .milliseconds(200)) {
        self.channels = ChannelStore(database)
        self.epg = EPGStore(database)
        self.library = LibraryStore(database)
        self.playlistID = playlistID
        self.minimumLength = minimumLength
        self.debounce = debounce
    }

    public var shouldSearch: Bool {
        query.trimmingCharacters(in: .whitespaces).count >= minimumLength
    }

    private func scheduleSearch() {
        task?.cancel()
        guard shouldSearch else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        // `[weak self]` plutôt qu'un `deinit` : sur une classe isolée à l'acteur
        // principal, `deinit` est non isolé et ne peut pas toucher la tâche. Une
        // référence faible suffit à ne pas retenir le modèle après la disparition
        // de la vue.
        task = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    /// Recherche immédiate, sans attendre — pour la touche « Rechercher » du clavier.
    public func searchNow() async {
        task?.cancel()
        guard shouldSearch else {
            results = []
            return
        }
        isSearching = true
        await performSearch()
    }

    private func performSearch() async {
        let text = query
        do {
            let records = try channels.search(text, playlistID: playlistID)
            guard !Task.isCancelled, text == query else { return }

            let keys = records.map(\.stableKey)
            let overrides = try library.overrides(for: keys)
            let favorites = Set(try library.favoriteChannels().map(\.key))
            let guide = playlistID.flatMap {
                try? epg.nowNext(channelKeys: keys, playlistID: $0)
            } ?? [:]

            results = records.map { record in
                ChannelListModel.Row(channel: record,
                                     override: overrides[record.key],
                                     now: guide[record.stableKey]?.current,
                                     next: guide[record.stableKey]?.next,
                                     isFavorite: favorites.contains(record.key))
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
        isSearching = false
    }

    public func clear() {
        task?.cancel()
        query = ""
        results = []
        isSearching = false
    }
}
