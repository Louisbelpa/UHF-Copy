import Foundation
import UHFCore
import UHFSources

/// Ce qu'on demande à lire.
public struct PlaybackItem: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var subtitle: String?
    public var artworkURL: URL?
    /// En-têtes imposés par la source (`#EXTVLCOPT`, en-têtes inline).
    public var httpHeaders: [String: String]
    /// Vrai pour une chaîne live : pas de barre de progression, reprise au direct.
    public var isLive: Bool
    /// Position de reprise, pour la VOD.
    public var startAt: TimeInterval?

    public init(url: URL, title: String, subtitle: String? = nil, artworkURL: URL? = nil,
                httpHeaders: [String: String] = [:], isLive: Bool = true,
                startAt: TimeInterval? = nil) {
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.httpHeaders = httpHeaders
        self.isLive = isLive
        self.startAt = startAt
    }
}

public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case ended
    case failed(PlaybackFailure)
}

public struct PlaybackFailure: Sendable, Equatable, LocalizedError {
    public enum Kind: Sendable, Equatable {
        case unsupportedFormat
        case network
        case forbidden
        case notFound
        case unknown
    }
    public var kind: Kind
    public var detail: String?

    public var errorDescription: String? {
        switch kind {
        case .unsupportedFormat: "Format non pris en charge par ce moteur."
        case .network: "Connexion interrompue."
        case .forbidden: "Accès refusé par le serveur (abonnement ou limite de connexions)."
        case .notFound: "Cette chaîne n'existe plus côté serveur."
        case .unknown: detail ?? "Lecture impossible."
        }
    }
}

public struct EngineCapabilities: Sendable, Equatable {
    public var pictureInPicture: Bool
    public var airPlay: Bool
    public var hdr: Bool
    public var spatialAudio: Bool
    public var audioTrackSelection: Bool
    public var subtitleSelection: Bool
}

/// Abstraction des deux moteurs de lecture.
///
/// L'existence même de ce protocole est la décision structurante du lecteur :
/// `AVPlayer` ne lit pas le MPEG-TS brut, format de sortie par défaut de la plupart
/// des panneaux Xtream, et `VLCKit` n'offre ni PiP ni AirPlay. Il en faut donc deux,
/// et le reste de l'app ne doit jamais savoir lequel est en service.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var capabilities: EngineCapabilities { get }
    var state: PlaybackState { get }
    /// Flux d'états, consommé par l'interface.
    var stateUpdates: AsyncStream<PlaybackState> { get }

    func load(_ item: PlaybackItem) async
    func play()
    func pause()
    func stop()
    func seek(to time: TimeInterval) async
    /// Retour au direct après une pause sur une chaîne live.
    func seekToLive() async
}
