import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Récupère une ressource distante **vers un fichier**, jamais en mémoire.
///
/// Un XMLTV pèse couramment 200 Mo : le charger dans un `Data` ferait tuer l'app par
/// le système sur iPhone. Tout ce qui vient du réseau et peut être volumineux passe
/// donc par le disque, et les parseurs lisent ce fichier en flux.
public protocol FileDownloading: Sendable {
    /// - Returns: l'emplacement local du fichier téléchargé. À l'appelant de le supprimer.
    func download(from url: URL,
                  headers: [String: String],
                  progress: @Sendable (Double?) -> Void) async throws -> URL
}

public struct URLSessionDownloader: FileDownloading {

    public enum Failure: Error, LocalizedError {
        case http(Int)
        case empty

        public var errorDescription: String? {
            switch self {
            case .http(let code): "Le serveur a répondu \(code)."
            case .empty: "Le serveur a renvoyé un fichier vide."
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func makeDefault() -> URLSessionDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // Un EPG volumineux sur une connexion lente a le droit de prendre son temps.
        configuration.timeoutIntervalForResource = 600
        return URLSessionDownloader(session: URLSession(configuration: configuration))
    }

    public func download(from url: URL,
                         headers: [String: String],
                         progress: @Sendable (Double?) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        // Beaucoup de panneaux servent l'EPG en gzip sans l'annoncer ; on l'accepte
        // explicitement, et ``Gunzip`` traitera le cas d'après la signature du fichier.
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-download-\(UUID().uuidString)")

        #if canImport(Darwin)
        // `download(for:)` écrit directement dans un fichier temporaire géré par le
        // système : aucune copie en mémoire, quelle que soit la taille de l'EPG.
        let (temporary, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.http(http.statusCode)
        }
        // Le fichier rendu par URLSession est supprimé dès le retour de cet appel :
        // il faut le déplacer immédiatement.
        try FileManager.default.moveItem(at: temporary, to: destination)

        // Une progression fine demanderait un `URLSessionDownloadDelegate` ; le
        // service de synchronisation rapporte de toute façon la phase en cours, ce
        // qui couvre l'essentiel du besoin d'interface.
        progress(nil)
        #else
        // Chemin Linux, utilisé uniquement pour le développement et les tests : les
        // téléchargements y sont petits, et le vrai chemin est celui ci-dessus.
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.http(http.statusCode)
        }
        guard !data.isEmpty else { throw Failure.empty }
        try data.write(to: destination)
        #endif

        let size = ((try? FileManager.default
            .attributesOfItem(atPath: destination.path))?[.size] as? Int) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.empty
        }

        progress(1)
        return destination
    }
}
