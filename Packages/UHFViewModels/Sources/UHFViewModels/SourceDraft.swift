import Foundation
import UHFCore
import UHFSources
import UHFStore

/// Ce que l'utilisateur saisit pour ajouter une source, et ce qu'on en déduit.
///
/// C'est le premier écran de l'app, et la première cause d'abandon : l'utilisateur
/// colle ce que son fournisseur lui a envoyé, sans savoir si c'est un « M3U » ou un
/// « Xtream ». Le rôle de ce type est de ne jamais le lui demander.
public struct SourceDraft: Sendable, Equatable {

    public enum Detected: Sendable, Equatable {
        /// URL `get.php` ou `player_api.php` : les identifiants y sont, on peut
        /// utiliser l'API Xtream, bien plus riche qu'un M3U (films, séries, EPG court).
        case xtream(baseURL: URL, username: String, password: String)
        /// Playlist M3U simple, éventuellement un fichier local.
        case m3u(URL)
        case invalid(reason: String)
    }

    public var name: String
    public var rawURL: String
    public var userAgent: String?

    public init(name: String = "", rawURL: String = "", userAgent: String? = nil) {
        self.name = name
        self.rawURL = rawURL
        self.userAgent = userAgent
    }

    /// Devine le type de source. Une URL `get.php` contenant des identifiants est
    /// toujours traitée en Xtream : le M3U qu'elle renvoie est un sous-ensemble.
    public var detected: Detected {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid(reason: "Renseignez l'adresse fournie par votre fournisseur.")
        }

        if let credentials = XtreamClient.Credentials(pastedURL: trimmed) {
            return .xtream(baseURL: credentials.baseURL,
                           username: credentials.username,
                           password: credentials.password)
        }

        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: withScheme), url.host != nil || url.isFileURL else {
            return .invalid(reason: "Cette adresse ne semble pas valide.")
        }
        return .m3u(url)
    }

    public var isValid: Bool {
        if case .invalid = detected { return false }
        return true
    }

    /// Nom proposé par défaut : celui saisi, sinon le domaine du serveur.
    public var suggestedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        switch detected {
        case .xtream(let baseURL, _, _): return baseURL.host ?? "Ma source"
        case .m3u(let url): return url.host ?? url.deletingPathExtension().lastPathComponent
        case .invalid: return "Ma source"
        }
    }

    /// Construit l'enregistrement à persister.
    ///
    /// - Note: les identifiants Xtream **ne sont pas** dans l'objet rendu. Ils sont
    ///   remis à l'appelant séparément, à charge pour lui de les mettre au Keychain :
    ///   un fichier SQLite finit dans les sauvegardes et les journaux de plantage.
    public func makeRecord(id: String = UUID().uuidString)
        -> (playlist: PlaylistRecord, credentials: (username: String, password: String)?)? {

        switch detected {
        case .xtream(let baseURL, let username, let password):
            return (PlaylistRecord(id: id, name: suggestedName, kind: .xtream, url: baseURL,
                                   credentialsRef: id, userAgent: userAgent),
                    (username, password))
        case .m3u(let url):
            return (PlaylistRecord(id: id, name: suggestedName, kind: .m3u, url: url,
                                   userAgent: userAgent), nil)
        case .invalid:
            return nil
        }
    }
}
