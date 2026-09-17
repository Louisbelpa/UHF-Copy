import Foundation
import UHFCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Moteur de lecture à employer pour un flux donné.
public enum PlaybackEngineKind: String, Sendable, Equatable {
    /// `AVPlayer` : HLS et conteneurs MP4. Seul à offrir PiP, AirPlay, HDR et Atmos.
    case avPlayer
    /// `VLCKit` : MPEG-TS brut, Matroska, et tout le reste.
    case vlcKit
}

/// Détermine quel moteur peut lire une URL.
///
/// C'est la décision structurante du lecteur : `AVPlayer` ne sait **pas** lire le
/// MPEG-TS brut en HTTP progressif, qui est pourtant la sortie par défaut de la
/// plupart des panneaux Xtream. Se tromper de moteur, c'est un écran noir.
///
/// La détection procède du moins cher au plus cher : extension, puis type MIME
/// annoncé, puis signature des premiers octets — car les serveurs IPTV mentent
/// régulièrement sur les deux premiers.
public struct StreamProbe: Sendable {

    public struct Outcome: Sendable, Equatable {
        public var engine: PlaybackEngineKind
        public var reason: Reason
        public var contentType: String?
        public var statusCode: Int?

        public enum Reason: String, Sendable {
            case fileExtension
            case contentType
            case magicBytes
            case fallback
        }
    }

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport.makeDefault()) {
        self.transport = transport
    }

    // MARK: - Décision hors ligne

    /// Décision sur la seule extension, sans aucune requête réseau.
    /// `nil` quand l'extension n'est pas concluante.
    public static func engine(forExtension pathExtension: String) -> PlaybackEngineKind? {
        switch pathExtension.lowercased() {
        case "m3u8", "m3u":
            .avPlayer
        case "mp4", "m4v", "mov":
            .avPlayer
        case "ts", "mpegts", "mts", "m2ts", "mkv", "avi", "flv", "wmv", "webm", "mpg", "mpeg":
            .vlcKit
        default:
            nil
        }
    }

    public static func engine(forContentType contentType: String) -> PlaybackEngineKind? {
        let type = contentType.lowercased()
            .split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        switch type {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl",
             "audio/mpegurl", "audio/x-mpegurl", "application/mpegurl":
            return .avPlayer
        case "video/mp4", "video/quicktime", "video/x-m4v":
            return .avPlayer
        case "video/mp2t", "video/mpeg", "application/x-mpegts",
             "video/x-matroska", "video/x-msvideo", "video/x-flv", "video/webm":
            return .vlcKit
        default:
            // `application/octet-stream` et `text/html` ne disent rien : c'est le cas
            // où seule la signature des octets tranchera.
            return nil
        }
    }

    /// Reconnaît le format aux premiers octets du flux. C'est le juge de paix :
    /// ni l'extension ni le type MIME ne sont fiables sur ces serveurs.
    public static func engine(forMagicBytes data: Data) -> PlaybackEngineKind? {
        let bytes = [UInt8](data.prefix(400))
        guard bytes.count >= 4 else { return nil }

        // Playlist HLS : le fichier commence par `#EXTM3U`, parfois précédé d'un BOM.
        let head = bytes.prefix(16)
        if let text = String(bytes: head, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines)
               .replacingOccurrences(of: "\u{FEFF}", with: "")
               .hasPrefix("#EXTM3U") {
            return .avPlayer
        }

        // MPEG-TS : octet de synchronisation 0x47 tous les 188 octets.
        if bytes[0] == 0x47, bytes.count > 188, bytes[188] == 0x47 {
            return .vlcKit
        }

        // Matroska / WebM : EBML `1A 45 DF A3`.
        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return .vlcKit
        }

        // ISO-BMFF (MP4/MOV) : « ftyp » en quatrième position.
        if bytes.count >= 8, bytes[4] == 0x66, bytes[5] == 0x74,
           bytes[6] == 0x79, bytes[7] == 0x70 {
            return .avPlayer
        }
        return nil
    }

    // MARK: - Sondage réseau

    /// Sonde l'URL et rend le moteur à employer.
    ///
    /// - Note: se limite aux 2 premiers kilo-octets. Ouvrir un flux live pour le
    ///   refermer aussitôt consomme une des connexions simultanées de l'abonnement,
    ///   souvent limitées à une ou deux.
    public func probe(_ url: URL, headers: [String: String] = [:]) async -> Outcome {
        if let engine = Self.engine(forExtension: url.pathExtension) {
            return Outcome(engine: engine, reason: .fileExtension)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        guard let (data, response) = try? await transport.data(for: request) else {
            // Réseau indisponible : VLCKit lit le sur-ensemble le plus large, c'est le
            // repli qui a le plus de chances d'afficher une image.
            return Outcome(engine: .vlcKit, reason: .fallback)
        }

        let contentType = response.headerValue(for: "Content-Type")

        if let engine = Self.engine(forMagicBytes: data) {
            return Outcome(engine: engine, reason: .magicBytes,
                           contentType: contentType, statusCode: response.statusCode)
        }
        if let contentType, let engine = Self.engine(forContentType: contentType) {
            return Outcome(engine: engine, reason: .contentType,
                           contentType: contentType, statusCode: response.statusCode)
        }
        return Outcome(engine: .vlcKit, reason: .fallback,
                       contentType: contentType, statusCode: response.statusCode)
    }
}

extension HTTPURLResponse {
    /// Accès à un en-tête insensible à la casse.
    ///
    /// Le nom diffère volontairement de `value(forHTTPHeaderField:)` : sur Darwin cette
    /// méthode existe déjà, et une extension de même signature s'appellerait elle-même
    /// indéfiniment — un plantage invisible depuis Linux, où la méthode est absente.
    fileprivate func headerValue(for field: String) -> String? {
        #if canImport(Darwin)
        return value(forHTTPHeaderField: field)
        #else
        let lowercased = field.lowercased()
        for (key, value) in allHeaderFields {
            if (key as? String)?.lowercased() == lowercased { return value as? String }
        }
        return nil
        #endif
    }
}
