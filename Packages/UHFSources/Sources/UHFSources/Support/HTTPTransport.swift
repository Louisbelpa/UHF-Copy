import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Point d'injection du réseau, pour que les clients soient testables sans serveur.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Configuration adaptée aux serveurs IPTV : timeouts courts pour ne pas laisser
    /// l'utilisateur devant un écran figé, et pas de cache disque sur les réponses API.
    public static func makeDefault(userAgent: String? = nil) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        #if canImport(Darwin)
        // Non réglable dans swift-corelibs-foundation, où ce paquet ne sert qu'aux tests.
        configuration.waitsForConnectivity = true
        #endif
        configuration.httpAdditionalHeaders = userAgent.map { ["User-Agent": $0] }
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XtreamError.malformedResponse("réponse non HTTP")
        }
        return (data, http)
    }
}
