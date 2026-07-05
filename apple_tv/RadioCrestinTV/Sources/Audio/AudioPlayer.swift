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

    /// True when the current source renders picture, not just audio:
    /// a TV station (always), or a playlist item of type `video`.
    /// Drives the full-bleed video layout in `NowPlayingView`.
    @Published private(set) var isVideoContent: Bool = false

    /// The playlist entry currently playing, or nil for radio/TV stations.
    @Published private(set) var currentPlaylistItem: PlaylistItem?

    /// 1-based index of the current playlist item and the total count —
    /// surfaced as "x / y" in the UI. Both 0 when not a playlist.
    @Published private(set) var playlistIndex: Int = 0
    @Published private(set) var playlistCount: Int = 0

    /// Playback position / duration (seconds) of the current VOD playlist
    /// item. `0` for live radio/TV. `duration` is 0 until known.
    @Published private(set) var vodPosition: Double = 0
    @Published private(set) var vodDuration: Double = 0

    /// True when the selected playlist station has entries but every one is
    /// YouTube — nothing tvOS can embed. The UI shows a friendly message.
    @Published private(set) var youTubeOnlyPlaylist: Bool = false

    /// True when a live playlist sync removed every playable item while
    /// the station was playing — the UI swaps to a friendly empty state.
    /// Cleared automatically if a later sync brings items back.
    @Published private(set) var playlistDepleted: Bool = false

    /// Repository used by the live playlist sync poller. Injected so
    /// tests can stub the network layer.
    private let repository: StationRepository

    private let player = AVPlayer()
    private var currentStation: Station?
    private var streams: [StationStream] = []
    private var attemptIndex = 0
    private var statusObserver: NSKeyValueObservation?
    private var playerItemObserver: AnyCancellable?

    /// Distinguishes the two playback engines sharing the single AVPlayer:
    /// sequential *stream* fallback (radio/TV) versus sequential *playlist*
    /// item advance (playlist stations).
    private enum PlaybackMode { case stream, playlist }
    private var playbackMode: PlaybackMode = .stream

    /// Ordered, playable (non-YouTube) items for the active playlist station.
    private var playlistItems: [PlaylistItem] = []

    /// Consecutive playlist-item load failures. Reset on any successful
    /// item start; when it reaches the item count we stop instead of
    /// spinning forever through a fully-broken playlist.
    private var consecutivePlaylistErrors = 0

    /// NotificationCenter token for `AVPlayerItemDidPlayToEndTime` on the
    /// current playlist item — drives auto-advance / loop.
    private var itemEndObserver: NSObjectProtocol?

    /// 5s poll loop that keeps the playlist in sync with the backend while
    /// the player screen is open. Started/stopped by `NowPlayingView`
    /// (appear/disappear + scenePhase).
    private var playlistSyncTask: Task<Void, Never>?

    /// Cadence of the live playlist sync poll.
    private static let playlistSyncInterval: TimeInterval = 5

    /// Periodic time observer feeding `vodPosition` for playlist VOD items.
    private var timeObserver: Any?

    /// Stream type the engine is currently feeding to AVPlayer. `nil`
    /// when no item is loaded. Public for metadata sync.
    private(set) var currentStreamType: String?

    /// Most recent DATERANGE `ID` seen on the active HLS playlist.
    /// Compared (not counted) so the same group emitted across consecutive
    /// playlist windows does not retrigger a refresh. Reset on item swap.
    private var lastSeenDateRangeID: String?

    /// Bridge for `AVPlayerItemMetadataCollector` — the collector requires
    /// an `NSObjectProtocol` delegate, which `AudioPlayer` is not.
    private var dateRangeCollector: AVPlayerItemMetadataCollector?
    private var dateRangeBridge: DateRangeBridge?

    /// Fired when a new DATERANGE `ID` appears on the active HLS playlist —
    /// signal that a song change was just announced. Wired up by `RootView`
    /// to trigger an out-of-cycle metadata poll, additive to the regular
    /// 10s `/stations-metadata` cadence.
    var onDateRangeMetadataChange: (() -> Void)?

    init(repository: StationRepository = StationRepository()) {
        self.repository = repository
        // Active audio session so the player keeps running when the
        // user backgrounds the app via Home button on the Siri Remote.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: []
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// The shared AVPlayer, exposed so `VideoSurfaceView` can attach an
    /// `AVPlayerLayer`. Read-only; all control still flows through this type.
    var avPlayer: AVPlayer { player }

    // MARK: - Public API

    func play(_ station: Station) {
        currentStation = station
        resetPlaylistState()

        switch station.kind {
        case .radio, .tv:
            // Live audio (radio) or live video (TV) — same sequential
            // stream fallback walk; TV just happens to carry picture.
            playbackMode = .stream
            isVideoContent = (station.kind == .tv)
            streams = station.orderedStreams
            attemptIndex = 0
            state = .connecting(station.title)
            loadCurrentAttempt()
            player.play()

        case .playlist:
            playbackMode = .playlist
            let items = station.playableItems
            guard !items.isEmpty else {
                // Nothing playable — surface the friendly YouTube-only
                // state rather than a spinning, broken player.
                youTubeOnlyPlaylist = station.hasOnlyYouTubeItems
                isVideoContent = false
                state = .idle
                return
            }
            playlistItems = items
            playlistCount = items.count
            loadPlaylistItem(at: 0)
            player.play()
        }
    }

    func togglePlayPause() {
        guard let station = currentStation else { return }
        switch state {
        case .playing:
            if playbackMode == .playlist {
                // Playlist items are on-demand files — a soft pause keeps
                // the buffered position so resume continues seamlessly.
                player.pause()
                state = .paused(station.title)
            } else {
                // Pause is a hard stop for live radio/TV. Holding the
                // buffered segments would let "resume" replay stale content
                // now seconds-to-minutes behind the live edge. Drop the
                // item to close the connection and clear the buffer.
                player.pause()
                player.replaceCurrentItem(with: nil)
                statusObserver?.invalidate()
                statusObserver = nil
                currentStreamType = nil
                state = .paused(station.title)
            }
        case .paused:
            if playbackMode == .playlist, player.currentItem != nil {
                // Resume the same on-demand item where it left off.
                player.play()
                state = .playing(station.title)
            } else {
                // Resume live = re-tune at the live edge (fresh playlist).
                play(station)
            }
        case .failed:
            play(station)
        case .connecting, .idle:
            break
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        stopPlaylistSync()
        resetPlaylistState()
        currentStreamType = nil
        isVideoContent = false
        state = .idle
    }

    // MARK: - Live playlist sync

    /// Begin the 5s playlist poll. Idempotent — a second call while the
    /// loop is running is a no-op, and non-playlist stations never start.
    /// Driven by `NowPlayingView` on appear / scene-active.
    func startPlaylistSync() {
        guard currentStation?.kind == .playlist else { return }
        guard playlistSyncTask == nil else { return }
        playlistSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds:
                        UInt64(Self.playlistSyncInterval * 1_000_000_000)
                )
                guard !Task.isCancelled else { break }
                await self?.syncPlaylistOnce()
            }
        }
    }

    /// Stop the playlist poll. Driven by `NowPlayingView` on disappear /
    /// scene-inactive, and by `stop()`.
    func stopPlaylistSync() {
        playlistSyncTask?.cancel()
        playlistSyncTask = nil
    }

    /// One poll iteration: fetch the server's current playlist and
    /// reconcile it into the playing list. Network errors and "station
    /// not in response" are silently skipped — the next tick retries.
    private func syncPlaylistOnce() async {
        guard let station = currentStation, station.kind == .playlist else {
            return
        }
        guard let items = try? await repository.fetchStationPlaylist(
            stationSlug: station.slug
        ) else { return }
        applyPlaylistUpdate(items)
    }

    /// Reconciles a freshly fetched playlist against the playing one.
    ///
    /// Semantics (matched against item `id`):
    /// * Current item still present → update list/count/index bookkeeping
    ///   only; playback is NOT touched (the index may shift when items
    ///   before it were removed).
    /// * Current item removed → advance to the next surviving playable
    ///   item, following the old order with wrap-around (loop rules).
    /// * Nothing playable survives → stop and flag `playlistDepleted` so
    ///   the UI shows the friendly empty state. A later sync with items
    ///   recovers automatically.
    ///
    /// YouTube filtering is re-applied on every sync.
    func applyPlaylistUpdate(_ rawItems: [PlaylistItem]) {
        guard playbackMode == .playlist else { return }
        let items = rawItems
            .filter { !$0.isYouTube }
            .sorted { $0.order < $1.order }
        guard items != playlistItems else { return }

        if items.isEmpty {
            depletePlaylist()
            return
        }
        playlistDepleted = false
        youTubeOnlyPlaylist = false

        let previousItems = playlistItems
        let currentId = currentPlaylistItem?.id
        playlistItems = items
        playlistCount = items.count

        if let currentId,
           let newIndex = items.firstIndex(where: { $0.id == currentId }) {
            // Current item survived — refresh bookkeeping (index shifts if
            // earlier items were removed; title/thumbnail may have been
            // edited) without interrupting the AVPlayer item.
            playlistIndex = newIndex
            currentPlaylistItem = items[newIndex]
            return
        }

        // Current item removed (or nothing was playing — e.g. the list
        // was previously depleted / YouTube-only): start the next
        // surviving item.
        consecutivePlaylistErrors = 0
        let target = nextSurvivingIndex(
            afterRemoved: currentId, oldItems: previousItems, newItems: items
        )
        loadPlaylistItem(at: target)
        player.play()
    }

    /// Index (in `newItems`) of the first item that follows the removed
    /// current item in the *old* order and survived the sync, wrapping
    /// around the end. Falls back to 0 when there is no reference point.
    private func nextSurvivingIndex(
        afterRemoved removedId: Int?,
        oldItems: [PlaylistItem],
        newItems: [PlaylistItem]
    ) -> Int {
        guard let removedId,
              let oldIdx = oldItems.firstIndex(where: { $0.id == removedId })
        else { return 0 }
        let survivors = Set(newItems.map(\.id))
        for offset in 1..<max(oldItems.count, 1) {
            let candidate = oldItems[(oldIdx + offset) % oldItems.count]
            if survivors.contains(candidate.id),
               let idx = newItems.firstIndex(where: { $0.id == candidate.id }) {
                return idx
            }
        }
        return 0
    }

    /// Every playable item was removed server-side while playing: tear
    /// down playback and flag the empty state. Keeps `playbackMode` and
    /// `currentStation` so a later sync can recover.
    private func depletePlaylist() {
        removeEndObserver()
        removeTimeObserver()
        statusObserver?.invalidate()
        statusObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playlistItems = []
        playlistCount = 0
        playlistIndex = 0
        currentPlaylistItem = nil
        isVideoContent = false
        vodPosition = 0
        vodDuration = 0
        playlistDepleted = true
        state = .idle
    }

    // MARK: - Playlist controls

    /// Advance to the next playlist item (wraps to the first). Manual —
    /// does not count against the broken-playlist error budget.
    func nextItem() {
        guard playbackMode == .playlist, !playlistItems.isEmpty else { return }
        consecutivePlaylistErrors = 0
        let next = (playlistIndex + 1) % playlistItems.count
        loadPlaylistItem(at: next)
        player.play()
    }

    /// Go to the previous playlist item (wraps to the last).
    func previousItem() {
        guard playbackMode == .playlist, !playlistItems.isEmpty else { return }
        consecutivePlaylistErrors = 0
        let prev = playlistIndex == 0 ? playlistItems.count - 1 : playlistIndex - 1
        loadPlaylistItem(at: prev)
        player.play()
    }

    /// Seek the current VOD item by `seconds` (negative = backward),
    /// clamped to the item bounds. No-op for live streams.
    func seek(by seconds: Double) {
        guard playbackMode == .playlist, let item = player.currentItem else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        var target = max(0, current + seconds)
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            target = min(target, max(0, duration - 0.5))
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        vodPosition = target
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
    ///
    /// Gated to radio stations: TV video streams may also be HLS, but their
    /// now-playing song metadata isn't offset-synced, so they must not drive
    /// the audio-aligned metadata fetch.
    var hlsPlaybackTimestamp: Int? {
        guard currentStation?.kind == .radio,
              currentStreamType == "HLS",
              let date = hlsPlaybackDate else {
            return nil
        }
        return roundedTimestamp(at: date)
    }

    /// True when the currently loaded item is a radio HLS stream — the only
    /// case where offset-aligned song metadata applies. TV/playlist return
    /// false even when their underlying stream happens to be HLS.
    var isPlayingHls: Bool {
        currentStation?.kind == .radio && currentStreamType == "HLS"
    }

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
        // Cap the forward buffer at 6s so the audio the user hears stays
        // close to the live broadcast moment. The HLS playlists ship 6s
        // segments with EXT-X-PROGRAM-DATE-TIME, so one segment of buffer
        // is enough to keep stalls rare while keeping the now-playing
        // metadata visibly in sync with the audio. AVPlayer's default
        // stall-protection (`automaticallyWaitsToMinimizeStalling`) is
        // intentionally left on — the user asked for "live without too
        // much buffer, keep some defaults", not aggressive low-latency.
        item.preferredForwardBufferDuration = 6
        observe(item: item)
        // Only radio streams carry EXT-X-DATERANGE song announcements that
        // should drive an out-of-cycle metadata poll. TV video streams may
        // be HLS too, but their now-playing isn't song-synced.
        if currentStation?.kind == .radio {
            attachDateRangeCollector(to: item)
        }
        player.replaceCurrentItem(with: item)
    }

    // MARK: - Playlist playback

    /// Load and observe the playlist item at `index`. Sets up the VOD time
    /// observer and the end-of-item auto-advance hook.
    private func loadPlaylistItem(at index: Int) {
        guard index >= 0, index < playlistItems.count else { return }
        playlistIndex = index
        let playlistItem = playlistItems[index]
        currentPlaylistItem = playlistItem
        isVideoContent = playlistItem.isVideo
        currentStreamType = nil          // playlist items aren't HLS-synced
        vodPosition = 0
        vodDuration = playlistItem.durationSeconds.map(Double.init) ?? 0

        guard let url = Self.trackedURL(for: playlistItem.url) else {
            advancePlaylistItem(dueToError: true)
            return
        }
        if let title = currentStation?.title { state = .connecting(title) }

        let item = AVPlayerItem(url: url)
        // VOD: let AVPlayer choose the buffer (0 = automatic). The 6s live
        // cap used for radio/TV would starve on-demand playback.
        item.preferredForwardBufferDuration = 0
        observe(item: item)
        player.replaceCurrentItem(with: item)
        addEndObserver(for: item)
        addTimeObserver()
    }

    /// Advance to the next item, looping at the end. When `dueToError` and
    /// every item has failed in a row, stop instead of looping forever.
    private func advancePlaylistItem(dueToError: Bool) {
        guard !playlistItems.isEmpty else { return }
        if dueToError {
            consecutivePlaylistErrors += 1
            if consecutivePlaylistErrors >= playlistItems.count {
                state = .failed("Nu am putut reda playlistul")
                removeEndObserver()
                removeTimeObserver()
                return
            }
        }
        let next = playlistIndex + 1
        loadPlaylistItem(at: next < playlistItems.count ? next : 0)
        player.play()
    }

    /// Register the end-of-item notification that drives auto-advance/loop.
    private func addEndObserver(for item: AVPlayerItem) {
        removeEndObserver()
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advancePlaylistItem(dueToError: false)
            }
        }
    }

    private func removeEndObserver() {
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
        itemEndObserver = nil
    }

    /// Periodic (0.5s) observer that publishes the current VOD position and
    /// keeps `vodDuration` in sync once AVPlayer resolves the item length.
    private func addTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.vodPosition = time.seconds.isFinite ? time.seconds : 0
                if let duration = self.player.currentItem?.duration.seconds,
                   duration.isFinite, duration > 0 {
                    self.vodDuration = duration
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    /// Tear down all playlist bookkeeping. Called before every `play(_:)`
    /// and on `stop()` so a switch between station kinds starts clean.
    private func resetPlaylistState() {
        removeEndObserver()
        removeTimeObserver()
        playlistItems = []
        playlistIndex = 0
        playlistCount = 0
        currentPlaylistItem = nil
        consecutivePlaylistErrors = 0
        vodPosition = 0
        vodDuration = 0
        youTubeOnlyPlaylist = false
        playlistDepleted = false
    }

    /// Wire an `AVPlayerItemMetadataCollector` onto the new item so the
    /// server's `EXT-X-DATERANGE` entries surface in-app. Additive to the
    /// 10s metadata REST poll — early-trigger only, never replaces.
    private func attachDateRangeCollector(to item: AVPlayerItem) {
        // Reset so the first DATERANGE on the new stream registers as a
        // change rather than colliding with the previous stream's ID.
        lastSeenDateRangeID = nil
        let bridge = DateRangeBridge { [weak self] newID in
            Task { @MainActor in
                guard let self else { return }
                guard newID != self.lastSeenDateRangeID else { return }
                self.lastSeenDateRangeID = newID
                self.onDateRangeMetadataChange?()
            }
        }
        let collector = AVPlayerItemMetadataCollector()
        collector.setDelegate(bridge, queue: .main)
        item.add(collector)
        dateRangeBridge = bridge
        dateRangeCollector = collector
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
                    // A clean start clears the broken-playlist error budget.
                    if self.playbackMode == .playlist {
                        self.consecutivePlaylistErrors = 0
                    }
                case .failed:
                    switch self.playbackMode {
                    case .stream:
                        self.advanceOrFail(error: item.error)
                    case .playlist:
                        if let error = item.error {
                            Analytics.captureError(
                                error,
                                context: "avplayer_playlist_item_failed",
                                extra: [
                                    "station_slug": self.currentStation?.slug ?? "?",
                                    "item_index": self.playlistIndex
                                ]
                            )
                        }
                        self.advancePlaylistItem(dueToError: true)
                    }
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

// MARK: - DATERANGE delegate bridge

/// `NSObject`-conforming bridge for `AVPlayerItemMetadataCollector` —
/// `AudioPlayer` itself is a plain `final class`, so it cannot adopt the
/// `AVPlayerItemMetadataCollectorPushDelegate` protocol directly.
/// Compares each new group's HLS `ID` attribute by suffix, not the full
/// vendor-prefixed identifier (`com.apple.quicktime.HLS.id`), so the
/// match stays stable across iOS releases.
private final class DateRangeBridge: NSObject,
    AVPlayerItemMetadataCollectorPushDelegate {
    private let onNewID: (String) -> Void

    init(onNewID: @escaping (String) -> Void) {
        self.onNewID = onNewID
        super.init()
    }

    func metadataCollector(
        _ metadataCollector: AVPlayerItemMetadataCollector,
        didCollect metadataGroups: [AVDateRangeMetadataGroup],
        indexesOfNewGroups: IndexSet,
        indexesOfModifiedGroups: IndexSet
    ) {
        // The "current song" is the most recently announced DATERANGE —
        // pick the new group with the latest startDate.
        var latest: (date: Date, id: String)?
        for index in indexesOfNewGroups {
            guard index < metadataGroups.count else { continue }
            let group = metadataGroups[index]
            guard let id = Self.dateRangeID(in: group.items) else { continue }
            if latest == nil || group.startDate > latest!.date {
                latest = (group.startDate, id)
            }
        }
        guard let id = latest?.id else { return }
        onNewID(id)
    }

    /// Pulls the DATERANGE `ID` attribute out of an `AVMetadataItem` array.
    /// AVFoundation maps DATERANGE attributes to identifiers shaped like
    /// `com.apple.quicktime.HLS.id` / `…HLS.x-title` — match by suffix so
    /// the lookup survives identifier-domain churn.
    private static func dateRangeID(in items: [AVMetadataItem]) -> String? {
        for item in items {
            guard let identifier = item.identifier?.rawValue.lowercased() else {
                continue
            }
            // Suffix `.id` (e.g. `com.apple.quicktime.HLS.id`) — a whole-string
            // `id` check would also match unrelated identifiers, so anchor on
            // the dot separator.
            if identifier.hasSuffix(".id") || identifier == "id" {
                if let str = item.stringValue, !str.isEmpty {
                    return str
                }
            }
        }
        return nil
    }
}
