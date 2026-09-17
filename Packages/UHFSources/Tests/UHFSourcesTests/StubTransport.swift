import Foundation
import UHFSources
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport de test : renvoie une réponse figée selon l'`action` demandée,
/// et enregistre les URLs appelées pour pouvoir les vérifier.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (status: Int, body: String)] = [:]
    private(set) var requestedURLs: [URL] = []

    init() {}

    func stub(action: String, status: Int = 200, body: String) {
        lock.lock(); defer { lock.unlock() }
        responses[action] = (status, body)
    }

    /// `lock()`/`unlock()` sont interdits directement dans un contexte asynchrone :
    /// l'accès à l'état est donc isolé dans cette méthode synchrone.
    private func take(_ url: URL) -> (status: Int, body: String)? {
        lock.lock()
        defer { lock.unlock() }
        requestedURLs.append(url)
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "action" }?.value ?? ""
        return responses[action]
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let entry = take(url)

        guard let entry else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404,
                                            httpVersion: nil, headerFields: nil)!)
        }
        return (Data(entry.body.utf8),
                HTTPURLResponse(url: url, statusCode: entry.status,
                                httpVersion: nil, headerFields: nil)!)
    }
}
