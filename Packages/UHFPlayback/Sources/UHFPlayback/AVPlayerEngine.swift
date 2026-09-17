import Foundation
import UHFCore
import UHFSources
#if canImport(AVFoundation)
import AVFoundation
import MediaPlayer

/// Moteur `AVPlayer` : HLS et conteneurs MP4.
///
/// C'est le moteur à privilégier chaque fois que c'est possible — lui seul donne le
/// Picture-in-Picture, AirPlay, le HDR/Dolby Vision et l'audio spatial, et il est
/// nettement plus économe en batterie que le décodage logiciel.
@MainActor
public final class AVPlayerEngine: PlaybackEngine {

    public let kind: PlaybackEngineKind = .avPlayer

    public let capabilities = EngineCapabilities(
        pictureInPicture: true, airPlay: true, hdr: true,
        spatialAudio: true, audioTrackSelection: true, subtitleSelection: true)

    public private(set) var state: PlaybackState = .idle {
        didSet { continuation?.yield(state) }
    }

    public let stateUpdates: AsyncStream<PlaybackState>
    private var continuation: AsyncStream<PlaybackState>.Continuation?

    /// Exposé pour être branché à `AVPlayerViewController`, qui fournit gratuitement
    /// les contrôles système, le PiP et le sélecteur AirPlay.
    public let player = AVPlayer()

    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var currentItem: PlaybackItem?

    public init() {
        var capturedContinuation: AsyncStream<PlaybackState>.Continuation?
        stateUpdates = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation

        player.automaticallyWaitsToMinimizeStalling = true
    }

    deinit {
        statusObservation?.invalidate()
        bufferObservation?.invalidate()
        continuation?.finish()
    }

    // MARK: - Chargement

    public func load(_ item: PlaybackItem) async {
        currentItem = item
        state = .loading

        let asset = AVURLAsset(url: item.url, options: Self.assetOptions(for: item))
        let playerItem = AVPlayerItem(asset: asset)

        // Sur une chaîne live, une fenêtre de buffer courte réduit nettement le délai
        // de zapping ; sur de la VOD elle provoquerait des ralentissements.
        playerItem.preferredForwardBufferDuration = item.isLive ? 2 : 0

        observe(playerItem)
        player.replaceCurrentItem(with: playerItem)

        if let startAt = item.startAt, !item.isLive {
            await seek(to: startAt)
        }
        configureNowPlaying(for: item)
        player.play()
    }

    /// - Important: `AVURLAssetHTTPHeaderFieldsKey` n'est pas une constante publique
    ///   d'AVFoundation. Elle fonctionne et est très employée, mais reste un détail
    ///   d'implémentation : Apple peut la retirer, et un examinateur pointilleux peut
    ///   la relever. L'alternative officielle est un `AVAssetResourceLoaderDelegate`
    ///   qui refait les requêtes à la main — beaucoup plus de code, et incompatible
    ///   avec le HLS chiffré. À trancher avant la mise en production ; en attendant,
    ///   l'absence d'en-tête personnalisé fait échouer une bonne part des serveurs.
    private static func assetOptions(for item: PlaybackItem) -> [String: Any] {
        guard !item.httpHeaders.isEmpty else { return [:] }
        return ["AVURLAssetHTTPHeaderFieldsKey": item.httpHeaders]
    }

    private func observe(_ playerItem: AVPlayerItem) {
        statusObservation?.invalidate()
        bufferObservation?.invalidate()

        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay: self.state = .playing
                case .failed: self.state = .failed(Self.classify(item.error))
                default: break
                }
            }
        }

        bufferObservation = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) {
            [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.state != .paused else { return }
                self.state = item.isPlaybackLikelyToKeepUp ? .playing : .buffering
            }
        }
    }

    /// Traduit l'erreur AVFoundation en cause compréhensible.
    ///
    /// `AVPlayer` renvoie `-11800` (« opération impossible ») pour à peu près tout,
    /// y compris pour un flux MPEG-TS qu'il ne sait pas lire : ce cas précis est le
    /// signal qu'il faut basculer sur VLCKit.
    static func classify(_ error: Error?) -> PlaybackFailure {
        guard let error = error as NSError? else { return PlaybackFailure(kind: .unknown, detail: nil) }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            switch underlying.code {
            case -12660, 403: return PlaybackFailure(kind: .forbidden, detail: nil)
            case -12661, 404: return PlaybackFailure(kind: .notFound, detail: nil)
            default: break
            }
        }
        switch error.code {
        case -11800, -11828, -11829:
            return PlaybackFailure(kind: .unsupportedFormat, detail: error.localizedDescription)
        case -1001, -1004, -1005, -1009:
            return PlaybackFailure(kind: .network, detail: error.localizedDescription)
        default:
            return PlaybackFailure(kind: .unknown, detail: error.localizedDescription)
        }
    }

    // MARK: - Transport

    public func play() {
        player.play()
        state = .playing
    }

    public func pause() {
        player.pause()
        state = .paused
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation?.invalidate()
        bufferObservation?.invalidate()
        state = .idle
    }

    public func seek(to time: TimeInterval) async {
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func seekToLive() async {
        guard let seekable = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        await player.seek(to: CMTimeRangeGetEnd(seekable))
        player.play()
    }

    // MARK: - Contrôles système

    /// Alimente l'écran verrouillé, le centre de contrôle et la télécommande Apple TV.
    /// Sans cela, la lecture paraît « non déclarée » au système et les boutons
    /// physiques ne font rien.
    private func configureNowPlaying(for item: PlaybackItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyIsLiveStream: item.isLive,
        ]
        if let subtitle = item.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
#endif
