import Foundation
import UHFCore
import UHFSources

// VLCKit se nomme différemment selon la plateforme, et n'est pas une dépendance SPM
// officielle : il s'ajoute via CocoaPods (`MobileVLCKit`, `TVVLCKit`) ou en XCFramework.
// Ce fichier compile donc dans les deux cas, avec ou sans VLCKit présent.
#if canImport(MobileVLCKit)
import MobileVLCKit
#elseif canImport(TVVLCKit)
import TVVLCKit
#endif

#if canImport(MobileVLCKit) || canImport(TVVLCKit)

/// Moteur `VLCKit` : MPEG-TS brut, Matroska, et tout ce qu'`AVPlayer` refuse.
///
/// - Important: décodage largement logiciel, donc ni PiP, ni AirPlay, ni HDR, et une
///   consommation de batterie sensiblement supérieure. C'est le moteur de repli, pas
///   le moteur par défaut : il ne sert que quand `AVPlayer` ne peut rien faire.
/// - Note: libVLC est sous licence **LGPL**. La liaison doit rester dynamique, la
///   mention doit figurer dans les crédits de l'app, et les sources de libVLC doivent
///   être mises à disposition. Compatible App Store, mais à préparer avant publication.
@MainActor
public final class VLCKitEngine: NSObject, PlaybackEngine {

    public let kind: PlaybackEngineKind = .vlcKit

    public let capabilities = EngineCapabilities(
        pictureInPicture: false, airPlay: false, hdr: false,
        spatialAudio: false, audioTrackSelection: true, subtitleSelection: true)

    public private(set) var state: PlaybackState = .idle {
        didSet { continuation?.yield(state) }
    }

    public let stateUpdates: AsyncStream<PlaybackState>
    private var continuation: AsyncStream<PlaybackState>.Continuation?

    /// À rattacher à la vue d'affichage (`drawable`).
    public let mediaPlayer = VLCMediaPlayer()

    public override init() {
        var capturedContinuation: AsyncStream<PlaybackState>.Continuation?
        stateUpdates = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation
        super.init()
        mediaPlayer.delegate = self
    }

    deinit { continuation?.finish() }

    public func load(_ item: PlaybackItem) async {
        state = .loading
        let media = VLCMedia(url: item.url)

        // VLCKit passe les en-têtes par ses options de média, pas par URLRequest.
        if let userAgent = item.httpHeaders["User-Agent"] {
            media.addOption(":http-user-agent=\(userAgent)")
        }
        if let referer = item.httpHeaders["Referer"] {
            media.addOption(":http-referrer=\(referer)")
        }
        // Mémoire tampon réseau : 1 s suffit en live et garde le zapping réactif.
        media.addOption(":network-caching=1000")

        mediaPlayer.media = media
        if let startAt = item.startAt, !item.isLive {
            mediaPlayer.time = VLCTime(int: Int32(startAt * 1000))
        }
        mediaPlayer.play()
    }

    public func play() { mediaPlayer.play() }
    public func pause() { mediaPlayer.pause() }
    public func stop() { mediaPlayer.stop(); state = .idle }

    public func seek(to time: TimeInterval) async {
        mediaPlayer.time = VLCTime(int: Int32(time * 1000))
    }

    public func seekToLive() async {
        mediaPlayer.position = 1.0
    }
}

extension VLCKitEngine: VLCMediaPlayerDelegate {
    public nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor in
            switch mediaPlayer.state {
            case .playing: state = .playing
            case .paused: state = .paused
            case .buffering, .opening: state = .buffering
            case .ended, .stopped: state = .ended
            case .error: state = .failed(PlaybackFailure(kind: .unknown, detail: "VLCKit"))
            default: break
            }
        }
    }
}
#endif
