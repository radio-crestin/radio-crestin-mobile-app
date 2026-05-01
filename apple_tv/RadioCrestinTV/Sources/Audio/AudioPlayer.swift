import AVFoundation
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// AVPlayer-backed audio engine for the tvOS app.
///
/// Mirrors the Android handler's contract: feed it a Station and it walks
/// the API-ordered streams[] until one starts playing. Caller observes
/// `state` to render play/pause/buffering.
///
/// In addition to playback, this type exposes:
///   * `currentStreamType` — "HLS" / "direct_stream" / nil. Used by the
///     metadata sync to pick the right query timestamp.
///   * `hlsPlaybackTimestamp` — the EXT-X-PROGRAM-DATE-TIME of the audio
///     currently being heard (rounded to 10s). Mirrors the Flutter
///     `getHlsPlaybackTimestamp` callback so the Apple TV app can fetch
///     `now_playing` aligned with the actual broadcast moment instead of
///     wall-clock — important because HLS has a 6–30s buffer.
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

    /// Stream type the engine is currently feeding to AVPlayer. `nil`
    /// when no item is loaded. Public for metadata sync.
    private(set) var currentStreamType: String?

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
        currentStreamType = nil
        state = .idle
    }

    // MARK: - Stream-time accessors (for metadata sync)

    /// Wall-clock date of the audio currently being heard, derived from
    /// `EXT-X-PROGRAM-DATE-TIME`. Only present for HLS streams that
    /// embed the tag — radiocrestin.ro's HLS playlists do.
    var hlsPlaybackDate: Date? {
        player.currentItem?.currentDate()
    }

    /// 10s-aligned Unix timestamp of the audio currently being heard for
    /// the active HLS stream, suitable as the `?timestamp=` parameter on
    /// `/api/v1/stations-metadata`. Returns nil for non-HLS streams or
    /// before the playlist has been parsed.
    var hlsPlaybackTimestamp: Int? {
        guard currentStreamType == "HLS", let date = hlsPlaybackDate else {
            return nil
        }
        return roundedTimestamp(at: date)
    }

    /// True when the currently loaded item is an HLS stream.
    var isPlayingHls: Bool { currentStreamType == "HLS" }

    // MARK: - Internals

    private func loadCurrentAttempt() {
        guard attemptIndex < streams.count,
              let url = Self.trackedURL(for: streams[attemptIndex].streamUrl)
        else {
            // Out of streams. Keep the connecting state visible briefly so
            // the user sees something happened, then surface failure.
            state = .failed("Nu am putut conecta la flux")
            currentStreamType = nil
            return
        }

        currentStreamType = streams[attemptIndex].type
        let item = AVPlayerItem(url: url)
        observe(item: item)
        player.replaceCurrentItem(with: item)
    }

    // MARK: - Stream URL tracking

    /// Per-install device id used as the `s` query parameter on every
    /// stream URL. Persisted in UserDefaults so it stays stable across
    /// launches (matches the Flutter `globals.deviceId` contract).
    private static let deviceId: String = {
        let key = "tv.streamDeviceId"
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            return saved
        }
        #if canImport(UIKit)
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            defaults.set(vendorId, forKey: key)
            return vendorId
        }
        #endif
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }()

    /// Adds `ref=radio-crestin-apple-tv&s=<deviceId>` to a stream URL so
    /// the streaming server can attribute listening sessions per-platform
    /// and per-device. Mirrors `AppAudioHandler.addTrackingParametersToUrl`
    /// in the Flutter app — same query-parameter contract.
    static func trackedURL(for streamUrl: String) -> URL? {
        guard let baseURL = URL(string: streamUrl),
              var components = URLComponents(
                  url: baseURL,
                  resolvingAgainstBaseURL: false
              )
        else { return URL(string: streamUrl) }

        var items = components.queryItems ?? []
        // Strip any pre-existing `ref` / `s` to avoid duplicate keys when
        // a stream URL is re-played in the same session.
        items.removeAll { $0.name == "ref" || $0.name == "s" }
        items.append(URLQueryItem(name: "ref", value: "radio-crestin-apple-tv"))
        items.append(URLQueryItem(name: "s", value: deviceId))
        components.queryItems = items
        return components.url ?? baseURL
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
            currentStreamType = nil
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
