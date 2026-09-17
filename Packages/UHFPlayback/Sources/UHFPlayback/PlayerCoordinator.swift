import Foundation
import UHFCore
import UHFSources

/// Choisit le moteur, bascule sur l'autre en cas d'échec, et mémorise la décision.
///
/// C'est la pièce qui rend les deux moteurs invisibles au reste de l'app. Sa règle
/// tient en une phrase : **tenter AVPlayer chaque fois que c'est plausible, retomber
/// sur VLCKit dès qu'il échoue, et ne plus se tromper deux fois pour la même chaîne.**
@MainActor
public final class PlayerCoordinator {

    /// Mémoire des basculements, indexée par ``StableKey`` et non par URL : les URLs
    /// de flux portent des jetons de session qui changent à chaque rafraîchissement.
    private var learned: [StableKey: PlaybackEngineKind] = [:]
    private let probe: StreamProbe
    private let makeEngine: @MainActor (PlaybackEngineKind) -> PlaybackEngine?

    public private(set) var current: PlaybackEngine?

    public init(probe: StreamProbe = StreamProbe(),
                makeEngine: @escaping @MainActor (PlaybackEngineKind) -> PlaybackEngine?) {
        self.probe = probe
        self.makeEngine = makeEngine
    }

    /// Restaure les décisions apprises lors des sessions précédentes.
    public func restore(_ decisions: [StableKey: PlaybackEngineKind]) {
        learned = decisions
    }

    public var decisions: [StableKey: PlaybackEngineKind] { learned }

    /// Lance la lecture, en basculant de moteur si le premier échoue sur un format
    /// qu'il ne sait pas lire.
    ///
    /// - Returns: le moteur finalement retenu, ou `nil` si aucun n'a abouti.
    @discardableResult
    public func play(_ item: PlaybackItem, key: StableKey) async -> PlaybackEngine? {
        let first: PlaybackEngineKind
        if let known = learned[key] {
            first = known
        } else {
            first = await probe.probe(item.url, headers: item.httpHeaders).engine
        }

        if let engine = await start(item, using: first) {
            learned[key] = first
            return engine
        }

        // Le premier moteur a échoué : l'autre est le seul recours.
        let second: PlaybackEngineKind = (first == .avPlayer) ? .vlcKit : .avPlayer
        if let engine = await start(item, using: second) {
            learned[key] = second
            return engine
        }
        return nil
    }

    private func start(_ item: PlaybackItem, using kind: PlaybackEngineKind) async -> PlaybackEngine? {
        guard let engine = makeEngine(kind) else { return nil }
        current?.stop()
        current = engine
        await engine.load(item)

        // On n'attend pas indéfiniment : un flux mort ne produit jamais d'erreur,
        // il reste simplement en chargement. Au-delà du délai, on considère l'échec.
        return await withTimeout(seconds: 12) {
            for await state in engine.stateUpdates {
                switch state {
                case .playing: return engine
                case .failed: return nil
                default: continue
                }
            }
            return nil
        }
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
