import Foundation

/// Identifiant stable et persistable d'un contenu.
///
/// Les `stream_id` des fournisseurs Xtream sont réattribués à chaque resynchronisation
/// de playlist : s'appuyer dessus fait sauter les favoris et l'historique de l'utilisateur.
/// `StableKey` est dérivée de données qui, elles, ne bougent pas : l'identité de la
/// playlist et le `tvg-id` de la chaîne (à défaut, son nom normalisé).
///
/// - Important: le hachage utilise FNV-1a et **jamais** `Hasher` de la bibliothèque
///   standard, dont la graine est aléatoire à chaque lancement du processus — une clé
///   écrite en base ne serait plus reconnue au démarrage suivant.
public struct StableKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    // MARK: - Fabriques

    /// Clé d'une chaîne live. `tvgID` prime ; à défaut on retombe sur le nom normalisé.
    public static func channel(playlistID: String, tvgID: String?, name: String) -> StableKey {
        let identity = Self.identity(tvgID: tvgID, name: name)
        return StableKey(rawValue: "ch_" + fnv1a("\(playlistID)\u{1F}\(identity)"))
    }

    /// Clé d'un film. Le titre normalisé + l'année survivent à un changement d'ID.
    public static func movie(playlistID: String, title: String, year: Int?) -> StableKey {
        let y = year.map(String.init) ?? ""
        return StableKey(rawValue: "mv_" + fnv1a("\(playlistID)\u{1F}\(title.normalizedForMatching)\u{1F}\(y)"))
    }

    /// Clé d'une série.
    public static func series(playlistID: String, title: String) -> StableKey {
        StableKey(rawValue: "sr_" + fnv1a("\(playlistID)\u{1F}\(title.normalizedForMatching)"))
    }

    /// Clé d'un épisode : rattachée à la série, pas au fournisseur.
    public static func episode(seriesKey: StableKey, season: Int, number: Int) -> StableKey {
        StableKey(rawValue: "ep_" + fnv1a("\(seriesKey.rawValue)\u{1F}\(season)x\(number)"))
    }

    static func identity(tvgID: String?, name: String) -> String {
        if let tvgID, !tvgID.trimmingCharacters(in: .whitespaces).isEmpty {
            return "id:" + tvgID.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return "nm:" + name.normalizedForMatching
    }

    /// FNV-1a 64 bits, rendu en hexadécimal. Déterministe entre lancements et plateformes.
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
