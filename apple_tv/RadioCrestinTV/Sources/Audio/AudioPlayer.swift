import AVFoundation
import Combine
import Foundation

/// AVPlayer-backed audio engine for the tvOS app.
///
/// Mirrors the Android handler's contract: feed it a Station and it walks
/// the API-ordered streams[] until one starts playing. Caller observes
/// `state` to render play/pause/buffering.
@MainActor
final class AudioPlayer: ObservableObject {
    enum PlaybackState: Equatable {
        case idle
        case connecting(String)   // station title
        case playing(String)
        case paused(String)
        case failed(String)       // error description
    }

    @Published private(set) var state: PlaybackState = .idle

    private let player = AVPlayer()
    private var currentStation: Station?
    private var streams: [StationStream] = []
    private var attemptIndex = 0
    private var statusObserver: NSKeyValueObservation?
    private var playerItemObserver: AnyCancellable?

    init() {
        // Active audio session so the player keeps running when the
        // user backgrounds the app via Home button on the Siri Remote.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: []
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Public API

    func play(_ station: Station) {
        currentStation = station
        streams = station.orderedStreams
        attemptIndex = 0
        state = .connecting(station.title)
        loadCurrentAttempt()
        player.play()
    }

    func togglePlayPause() {
        guard let station = currentStation else { return }
        switch state {
        case .playing:
            player.pause()
            state = .paused(station.title)
        case .paused, .failed:
            player.play()
            state = .playing(station.title)
        case .connecting, .idle:
            break
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        state = .idle
    }

    // MARK: - Internals

    private func loadCurrentAttempt() {
        guard attemptIndex < streams.count,
              let url = URL(string: streams[attemptIndex].streamUrl)
        else {
            // Out of streams. Keep the connecting state visible briefly so
            // the user sees something happened, then surface failure.
            state = .failed("Nu am putut conecta la flux")
            return
        }

        let item = AVPlayerItem(url: url)
        observe(item: item)
        player.replaceCurrentItem(with: item)
    }

    private func observe(item: AVPlayerItem) {
        // Drop the previous observation. AVPlayerItem.status is KVO-only.
        statusObserver?.invalidate()
        statusObserver = item.observe(
            \.status, options: [.new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    if let station = self.currentStation {
                        self.state = .playing(station.title)
                    }
                case .failed:
                    self.advanceOrFail(error: item.error)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func advanceOrFail(error: Error?) {
        attemptIndex += 1
        if attemptIndex < streams.count {
            // Retry the next stream — same UX as the Android fallback.
            loadCurrentAttempt()
        } else {
            state = .failed(
                error?.localizedDescription ?? "Eroare flux audio"
            )
            if let error {
                Analytics.captureError(
                    error,
                    context: "avplayer_stream_failed",
                    extra: [
                        "station_slug": currentStation?.slug ?? "?",
                        "stream_count": streams.count,
                        "last_attempted_url":
                            attemptIndex - 1 >= 0 && attemptIndex - 1 < streams.count
                                ? streams[attemptIndex - 1].streamUrl : "?"
                    ]
                )
            }
        }
    }
}

// MARK: - Convenience accessors for the UI

extension AudioPlayer {
    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }
    var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }
}
