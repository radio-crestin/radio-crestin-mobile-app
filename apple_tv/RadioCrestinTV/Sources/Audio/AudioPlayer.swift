import AVFoundation
import Combine
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// AVPlayer-backed audio engine for the tvOS app.
///
/// Mirrors the Android handler's contract: feed it a Station and it walks
/// the API-ordered streams[] until one plays. For live radio/TV,
/// `LiveStreamSupervisor` decides when a stream has failed the listener
/// (it never started, it stalled, AVPlayer gave up on it) and when to start
/// another round once every stream failed; this type owns AVPlayer and the
/// timers and carries those decisions out. Callers observe `state` and
/// `isRetrying` to render play/pause/buffering.
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

    /// True while every stream of the live station failed and the engine
    /// waits before trying them again; `state` is `.connecting` meanwhile.
    /// Lets the UI say it is retrying rather than just connecting.
    @Published private(set) var isRetrying: Bool = false

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

    /// True when the selected playlist station has entries but none is
    /// playable on tvOS (YouTube clips/playlists, unknown types). The UI
    /// shows a friendly message instead of a broken player.
    @Published private(set) var unplayableOnlyPlaylist: Bool = false

    /// True when a live playlist sync removed every playable item while
    /// the station was playing — the UI swaps to a friendly empty state.
    /// Cleared automatically if a later sync brings items back.
    @Published private(set) var playlistDepleted: Bool = false

    /// Repository used by the live playlist sync poller. Injected so
    /// tests can stub the network layer.
    private let repository: StationRepository

    /// Sends a playback failure to analytics: the error, a context and
    /// extra properties. Injected so tests do not report to the production
    /// project.
    typealias ErrorReporter = (Error, String, [String: Any]) -> Void
    private let reportError: ErrorReporter

    private let player = AVPlayer()
    private var currentStation: Station?

    /// Observes the current item (live attempt or playlist entry). Replaced,
    /// and the old one cancelled, whenever the item changes.
    private var itemObserver: PlayerItemObserver?

    /// Distinguishes the two playback engines sharing the single AVPlayer:
    /// sequential *stream* fallback (radio/TV) versus sequential *playlist*
    /// item advance (playlist stations).
    private enum PlaybackMode { case stream, playlist }
    private var playbackMode: PlaybackMode = .stream

    // MARK: Live stream state

    /// A live stream with its tracked URL already built, so a fallback never
    /// meets an unusable URL halfway through a round.
    private struct ResolvedStream {
        let source: StationStream
        let url: URL
    }

    /// The live station's streams that have a usable URL, in API order
    /// (HLS first, then the direct MP3/AAC stream).
    private var streams: [ResolvedStream] = []

    /// Decides when a live stream has failed and what to try next.
    private var supervisor = LiveStreamSupervisor()

    /// The supervisor's attempt whose item AVPlayer holds; nil while waiting
    /// to retry and whenever no live stream is wanted.
    private var liveAttemptID: Int?

    /// URL of the stream the last live attempt loaded, for analytics.
    private var lastAttemptedStreamUrl: String?

    /// Error AVFoundation gave for the current live attempt. Analytics gets
    /// it, or the supervisor's reason when AVPlayer reported none.
    private var liveAttemptError: Error?

    /// Periodic look at the player while the listener wants live audio.
    private var supervisionTask: Task<Void, Never>?

    /// How often the supervisor looks at the player. Its timeouts are 10 s,
    /// so a look each second decides within a tenth of them, and one wake-up
    /// a second (no per-frame work) costs nothing measurable.
    private static let supervisionInterval: Duration = .seconds(1)

    /// Lets tvOS batch that wake-up with others; a quarter of a second is
    /// irrelevant against 10 s timeouts.
    private static let supervisionTolerance: Duration = .milliseconds(250)

    /// Forward buffer AVPlayer may hold for a live item started at the live
    /// playlist: enough for everything between the playhead and the live
    /// edge. A start variant adds its offset (`liveForwardBuffer(for:)`).
    ///
    /// The HLS playlists start playback 18 s behind the live edge
    /// (`EXT-X-START:TIME-OFFSET=-18`) and the edge moves in 6 s segment
    /// steps, so up to ~24 s of audio already exists ahead of the playhead.
    /// Thirty seconds lets AVPlayer keep all of it, which bridges a network
    /// gap of that length without an audible break (the former 6 s cap made
    /// every gap over ~6–12 s audible).
    ///
    /// It adds no latency: how far behind live the listener hears is fixed
    /// by where playback starts, and a buffer can only hold audio that
    /// already exists, so it never pushes the playhead back. Nor can it
    /// misalign the song metadata: `hlsPlaybackTimestamp` reads the
    /// playhead's own `EXT-X-PROGRAM-DATE-TIME`, not the end of the buffer.
    /// Icecast MP3/AAC streams send a short burst and then real time, so
    /// the cap changes nothing for them.
    private static let liveForwardBufferDuration: TimeInterval = 30

    /// KVO on the player's control status and waiting reason, so the
    /// supervisor hears of a start or a stall at once rather than at its
    /// next look. Event-driven: nothing runs while they stay the same.
    private var playerObservations: [NSKeyValueObservation] = []

    /// Lets a retry wait end at once when the network comes back.
    private let networkWatcher = NetworkPathWatcher()

    /// Interruptions, lost outputs and background pauses: the system
    /// pausing the player must not look like a failed stream.
    private var systemEvents: SystemPlaybackEvents?

    /// Set when an audio interruption paused playback the listener wanted,
    /// so it resumes when the interruption ends — and only then.
    private var resumesAfterInterruption = false

    /// Keeps the app running in the background through an outage, so the
    /// retries go on while the listener is on the Home screen.
    private let backgroundKeeper = BackgroundAudioKeeper()

    /// How far behind live radio HLS starts: the "Încărcare în avans"
    /// setting, applied by `setSeekMode(_:)`.
    private(set) var seekMode: SeekMode = .default

    /// Holds the origin's radio HLS requests through a network outage, so
    /// AVPlayer plays it out from its forward buffer instead of giving up
    /// on the stream (see `HlsHoldProxy`).
    private let holdProxy = HlsHoldProxy(
        allowedHosts: HlsStartVariant.hosts,
        onEvent: { event in
            AudioPlayer.holdProxyLog.notice("\(event.description, privacy: .public)")
        }
    )

    /// Holds are rare (an outage), so each event is logged.
    private nonisolated static let holdProxyLog = Logger(
        subsystem: "ro.radiocrestin.tv", category: "HlsHoldProxy"
    )

    /// Streams whose start variant the origin does not publish: they start
    /// at their own playlist for the rest of the app's run.
    private var streamsWithoutVariant: Set<String> = []

    /// The stream whose start variant the current live attempt loaded; nil
    /// when it loaded the stream's own URL.
    private var liveAttemptVariantOf: ResolvedStream?

    // MARK: Playlist state

    /// Playable (non-YouTube) items for the active playlist station, in
    /// wire order — newest first, index 0 plays first.
    private var playlistItems: [PlaylistItem] = []

    /// Consecutive playlist-item load failures. Reset on any successful
    /// item start; when it reaches the item count we stop instead of
    /// spinning forever through a fully-broken playlist.
    private var consecutivePlaylistErrors = 0

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

    /// Announced song changes the audio has not reached yet, by DATERANGE
    /// `ID`. Cancelled with their item.
    private var songChangeWaits: [String: Task<Void, Never>] = [:]

    /// How often a song change wait looks at a playhead that has not yet
    /// reached the change (it stalled meanwhile): once a second, like the
    /// stream supervision. A change shown up to a second late is lost in
    /// the 10 s rounding of the fetch anyway.
    private static let songChangeRecheck: TimeInterval = 1

    /// Fired when the audio reaches a song change the HLS playlist
    /// announced with `EXT-X-DATERANGE`, so an audio-aligned metadata fetch
    /// now gets the new song. Wired by `PlaybackCoordinator`, additive to
    /// the periodic `/stations-metadata` poll.
    var onAudioReachedSongChange: (() -> Void)?

    init(
        repository: StationRepository = StationRepository(),
        reportError: @escaping ErrorReporter = {
            Analytics.captureError($0, context: $1, extra: $2)
        }
    ) {
        self.repository = repository
        self.reportError = reportError
        // Active audio session so the player keeps running when the
        // user backgrounds the app via Home button on the Siri Remote.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: []
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        // Every item keeps AVPlayer's stall-minimising wait and starts with
        // a plain `play()`. The former live fast-start (waiting off +
        // `playImmediately(atRate:)`) left every HLS station silent on
        // tvOS 27 (2026-10-30): timeControlStatus went playing → paused
        // within 20 ms and the item reached readyToPlay with 12 s buffered,
        // but the playhead never moved while the UI said "playing". With
        // the default wait the same streams play after 0.53 s (MP3 ~0.8 s),
        // so the fast-start gained nothing.
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayer()
        networkWatcher.onRestored = { [weak self] in
            self?.networkRestored()
        }
        systemEvents = SystemPlaybackEvents(player: player) {
            [weak self] event in
            self?.handleSystemEvent(event)
        }
    }

    /// The shared AVPlayer, exposed so `VideoSurfaceView` can attach an
    /// `AVPlayerLayer`. Read-only; all control still flows through this type.
    var avPlayer: AVPlayer { player }

    // MARK: - Public API

    func play(_ station: Station) {
        currentStation = station
        resumesAfterInterruption = false
        // Whatever played before — another station, kind or a pending
        // retry — stops here, so nothing of it can act on the new station.
        stopLiveSupervision()
        detachCurrentItem()
        resetPlaylistState()

        switch station.kind {
        case .radio, .tv:
            // Live audio (radio) or live video (TV) — same sequential
            // stream fallback walk; TV just happens to carry picture.
            playbackMode = .stream
            isVideoContent = (station.kind == .tv)
            streams = Self.resolvedStreams(of: station)
            guard !streams.isEmpty else {
                // No usable stream URL: retrying cannot fix that, so it is
                // the one terminal failure for a live station.
                state = .failed("Nu am putut conecta la flux")
                return
            }
            state = .connecting(station.title)
            apply(supervisor.start(
                streamCount: streams.count,
                joinOffset: station.kind == .radio ? seekMode.offset : 0,
                at: Self.now
            ))
            startSupervisionLoop()

        case .playlist:
            playbackMode = .playlist
            let items = station.playableItems
            guard !items.isEmpty else {
                // Nothing playable — surface the friendly unplayable
                // state rather than a spinning, broken player.
                unplayableOnlyPlaylist = station.hasOnlyUnplayableItems
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

    /// Pauses what the listener wants to hear, or resumes what they paused.
    /// A connection in progress or a pending retry counts as wanted, so the
    /// listener can always cancel it; `.idle` has nothing to toggle.
    func togglePlayPause() {
        guard let station = currentStation else { return }
        resumesAfterInterruption = false
        switch state {
        case .playing, .connecting:
            pausePlayback()
        case .paused:
            resumePlayback()
        case .failed:
            play(station)
        case .idle:
            break
        }
    }

    func stop() {
        resumesAfterInterruption = false
        stopLiveSupervision()
        detachCurrentItem()
        stopPlaylistSync()
        resetPlaylistState()
        isVideoContent = false
        state = .idle
    }

    /// Applies the "Încărcare în avans" setting. A live radio station the
    /// listener wants is tuned in again, so the new offset is heard now
    /// rather than from the next station on; one without HLS (MP3 only)
    /// plays live whatever the setting, and is left alone.
    func setSeekMode(_ mode: SeekMode) {
        guard mode != seekMode else { return }
        seekMode = mode
        guard playbackMode == .stream, wantsToPlay,
              let station = currentStation, station.kind == .radio,
              streams.contains(where: { $0.source.type == "HLS" })
        else { return }
        play(station)
    }

    /// The current station's catalog entry changed (same station, e.g. new
    /// stream URLs). Retries run until the listener gives up, so they must
    /// not keep cycling through URLs the API no longer lists: new streams
    /// take effect at the next retry round. A stream that plays, or a
    /// round in progress, is never cut for them.
    func stationDidUpdate(_ station: Station) {
        guard currentStation?.id == station.id else { return }
        currentStation = station
        adoptStreamsWhileWaiting()
    }

    private func pausePlayback() {
        guard let station = currentStation else { return }
        if playbackMode == .playlist {
            // Playlist items are on-demand files — a soft pause keeps
            // the buffered position so resume continues seamlessly.
            player.pause()
        } else {
            // Pause is a hard stop for live radio/TV, including a
            // connection in progress or a pending retry. Holding the
            // buffered segments would let "resume" replay stale content
            // now seconds-to-minutes behind the live edge. Drop the item
            // to close the connection and clear the buffer, and cancel
            // every timer so nothing restarts the audio later.
            stopLiveSupervision()
            detachCurrentItem()
        }
        state = .paused(station.title)
    }

    private func resumePlayback() {
        guard let station = currentStation else { return }
        if playbackMode == .playlist, let item = player.currentItem {
            // Resume the same on-demand item where it left off. One paused
            // before it was ready shows "connecting" until it is.
            player.play()
            state = item.status == .readyToPlay
                ? .playing(station.title) : .connecting(station.title)
        } else {
            // Resume live = re-tune at the live edge (fresh playlist).
            play(station)
        }
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
    ///   before it were removed, or by +1 per item inserted at the head —
    ///   the wire is newest-first, so new uploads arrive at position 0).
    /// * Current item removed → advance to the next surviving playable
    ///   item, following the old order with wrap-around (loop rules).
    /// * Nothing playable survives → stop and flag `playlistDepleted` so
    ///   the UI shows the friendly empty state. A later sync with items
    ///   recovers automatically.
    ///
    /// The playability allowlist (audio/video only) is re-applied on
    /// every sync.
    func applyPlaylistUpdate(_ rawItems: [PlaylistItem]) {
        guard playbackMode == .playlist else { return }
        // Same playability allowlist as `Station.playableItems`. Wire
        // order is preserved (newest-first from the backend) — a new
        // item lands at the HEAD, shifting later positions by +1; the
        // id-based reconciliation below absorbs that without touching
        // playback.
        let items = rawItems.filter(\.isPlayable)
        guard items != playlistItems else { return }

        if items.isEmpty {
            depletePlaylist()
            return
        }
        playlistDepleted = false
        unplayableOnlyPlaylist = false

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
        removeTimeObserver()
        detachCurrentItem()
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
    /// `EXT-X-PROGRAM-DATE-TIME` — radiocrestin.ro's HLS playlists carry
    /// it. Nil unless a radio HLS stream plays (see `isPlayingHls`), and
    /// until its item is ready.
    var hlsPlaybackDate: Date? {
        guard isPlayingHls, let item = player.currentItem else { return nil }
        return Self.playheadDate(of: item)
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
        hlsPlaybackDate.map { roundedTimestamp(at: $0) }
    }

    /// True when the currently loaded item is a radio HLS stream — the only
    /// case where offset-aligned song metadata applies. TV/playlist return
    /// false even when their underlying stream happens to be HLS.
    var isPlayingHls: Bool {
        currentStation?.kind == .radio && currentStreamType == "HLS"
    }

    /// The broadcast date of the audio at `item`'s playhead
    /// (`EXT-X-PROGRAM-DATE-TIME`), read only once the item is ready.
    ///
    /// Before that, `currentDate()` blocks the calling thread until the
    /// stream's server answers, while AVFoundation works out what kind of
    /// stream it is: on the main thread, the app froze for as long as the
    /// server took — two minutes for one that never answered (measured on
    /// the tvOS 27 simulator, 2026-10-31).
    private static func playheadDate(of item: AVPlayerItem) -> Date? {
        guard item.status == .readyToPlay else { return nil }
        return item.currentDate()
    }

    // MARK: - Live stream supervision

    /// Monotonic seconds for the supervisor: unlike the wall clock, it never
    /// jumps when the Apple TV sets its time, so no timeout fires early.
    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Carries out a supervisor decision and publishes what the listener
    /// should see.
    private func apply(_ action: LiveStreamSupervisor.Action) {
        switch action {
        case .none:
            break
        case .load(let stream, let attempt):
            loadLiveAttempt(stream: stream, attempt: attempt)
        case .waitForRetry(_, let report):
            // The periodic look ends the wait when it is due.
            detachCurrentItem()
            liveAttemptID = nil
            if report { reportStreamFailure() }
            adoptStreamsWhileWaiting()
        }
        publishLiveState()
        updateBackgroundKeeper()
    }

    /// Switches to the station's current streams if they changed, while
    /// waiting to retry: the only time no stream index is in use.
    private func adoptStreamsWhileWaiting() {
        guard playbackMode == .stream,
              supervisor.isWaitingToRetry,
              let station = currentStation
        else { return }
        let fresh = Self.resolvedStreams(of: station)
        guard fresh.map(\.source) != streams.map(\.source),
              supervisor.replaceStreams(count: fresh.count)
        else { return }
        streams = fresh
    }

    /// Runs the keeper while the app is in the background and the listener
    /// wants a live station that does not play: connecting, stalled or
    /// waiting to retry. In the foreground tvOS never suspends the app, so
    /// it stays off there. Called on every look (once a second at least),
    /// so a move to the background is caught within a second.
    private func updateBackgroundKeeper() {
        let silent = supervisor.display.map { $0 != .playing } ?? false
        backgroundKeeper.setRunning(
            playbackMode == .stream && silent && Self.isInBackground
        )
    }

    private static var isInBackground: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    private func loadLiveAttempt(stream index: Int, attempt: Int) {
        detachCurrentItem()
        let stream = streams[index]
        liveAttemptID = attempt
        liveAttemptError = nil
        lastAttemptedStreamUrl = stream.source.streamUrl
        let variant = startVariant(of: stream)
        liveAttemptVariantOf = variant == nil ? nil : stream
        loadLiveItem(from: variant ?? stream.url, of: stream, attempt: attempt)
    }

    /// Loads `url` (`stream`'s, or its start variant) for live `attempt`,
    /// through the hold proxy when it applies, directly otherwise.
    private func loadLiveItem(
        from url: URL, of stream: ResolvedStream, attempt: Int
    ) {
        currentStreamType = stream.source.type
        guard usesHoldProxy(stream) else {
            attachLiveItem(url: url, attempt: attempt)
            return
        }
        let proxy = holdProxy
        Task { [weak self] in
            // A loopback connection, well under a millisecond: tvOS may
            // have reclaimed the listening socket of the app while it was
            // suspended.
            let isRunning = await proxy.ensureRunning()
            // A pause, another station or the next stream came meanwhile.
            guard let self, self.liveAttemptID == attempt,
                  self.playbackMode == .stream
            else { return }
            // A new session per load: requests still held for the item it
            // replaces are released.
            let proxied = isRunning
                ? proxy.wrap(url, session: proxy.beginSession()) : nil
            self.attachLiveItem(url: proxied ?? url, attempt: attempt)
        }
    }

    private func attachLiveItem(url: URL, attempt: Int) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = liveForwardBuffer(
            startsBehindLive: liveAttemptVariantOf == nil ? 0 : seekMode.offset
        )
        itemObserver = PlayerItemObserver(item: item) { [weak self] event in
            self?.handleLiveItemEvent(event, attempt: attempt)
        }
        // Only radio streams carry EXT-X-DATERANGE song announcements that
        // should drive an out-of-cycle metadata poll. TV video streams may
        // be HLS too, but their now-playing isn't song-synced.
        if currentStation?.kind == .radio {
            attachDateRangeCollector(to: item)
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    /// The forward buffer for a live item that starts `offset` seconds
    /// further behind live than the live playlist: all the audio between
    /// its playhead and the live edge, so an outage that long is not heard.
    private func liveForwardBuffer(
        startsBehindLive offset: TimeInterval
    ) -> TimeInterval {
        offset + Self.liveForwardBufferDuration
    }

    /// The start variant to load for `stream`: radio HLS of the origin,
    /// behind live per the setting, unless the origin lacks its variant.
    private func startVariant(of stream: ResolvedStream) -> URL? {
        guard currentStation?.kind == .radio,
              stream.source.type == "HLS",
              !streamsWithoutVariant.contains(stream.source.streamUrl)
        else { return nil }
        return HlsStartVariant.url(for: stream.url, mode: seekMode)
    }

    /// Whether `stream` loads through the hold proxy: radio HLS of the
    /// origin, the remote kill switch on.
    private func usesHoldProxy(_ stream: ResolvedStream) -> Bool {
        currentStation?.kind == .radio
            && stream.source.type == "HLS"
            && HlsHoldProxyFlag.isEnabled
            && stream.url.host.map {
                HlsStartVariant.hosts.contains($0.lowercased())
            } ?? false
    }

    /// The origin answered the attempt's start variant with "not found":
    /// it does not publish one for this stream (not deployed there yet).
    /// The stream's own playlist loads at once, in the same attempt: that
    /// is no stream failure, the stream itself may well be fine. It skips
    /// the variant from now on.
    private func loadOwnPlaylist(
        instead stream: ResolvedStream, attempt: Int
    ) {
        streamsWithoutVariant.insert(stream.source.streamUrl)
        liveAttemptVariantOf = nil
        detachCurrentItem()
        loadLiveItem(from: stream.url, of: stream, attempt: attempt)
    }

    /// Whether an item failed with `error` because its playlist was not
    /// found. AVFoundation reports a playlist's HTTP 404 as
    /// `NSURLErrorFileDoesNotExist` over CoreMedia's -12938 ("HTTP 404:
    /// File Not Found"), with nothing in the item's error log yet
    /// (measured on tvOS 27, 2026-10-31). Internal for tests.
    static func isNotFound(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == NSURLErrorDomain,
           error.code == NSURLErrorFileDoesNotExist {
            return true
        }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == "CoreMediaErrorDomain"
            && underlying?.code == -12938
    }

    private func handleLiveItemEvent(
        _ event: PlayerItemObserver.Event, attempt: Int
    ) {
        guard playbackMode == .stream, attempt == liveAttemptID else { return }
        switch event {
        case .readyToPlay:
            // A ready item can make a `.playing` reading count.
            sampleLivePlayback()
        case .failed(let error):
            if let stream = liveAttemptVariantOf, Self.isNotFound(error) {
                loadOwnPlaylist(instead: stream, attempt: attempt)
                return
            }
            liveAttemptError = error
            apply(supervisor.attemptFailed(attempt, at: Self.now))
        case .failedToPlayToEnd(let error):
            liveAttemptError = error
            apply(supervisor.attemptFailed(attempt, at: Self.now))
        case .playedToEnd:
            // A live stream has no end: the server closed it.
            liveAttemptError = LiveStreamFailure.ended
            apply(supervisor.attemptFailed(attempt, at: Self.now))
        }
    }

    /// Gives the supervisor a fresh look at the player. It always reads
    /// the current item on the main actor, so a KVO change queued for a
    /// replaced item cannot speak for the new one.
    private func sampleLivePlayback() {
        guard playbackMode == .stream, let attempt = liveAttemptID else {
            return
        }
        let time = player.currentTime().seconds
        let audioDate = player.currentItem.flatMap(Self.playheadDate(of:))
        let sample = LiveStreamSupervisor.Sample(
            status: .init(
                timeControlStatus: player.timeControlStatus,
                waitingReason: player.reasonForWaitingToPlay,
                itemIsReady: player.currentItem?.status == .readyToPlay
            ),
            playhead: time.isFinite ? time : nil,
            liveLag: audioDate.map { Date().timeIntervalSince($0) }
        )
        apply(supervisor.record(sample, attempt: attempt, at: Self.now))
    }

    private func startSupervisionLoop() {
        supervisionTask?.cancel()
        supervisionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: Self.supervisionInterval,
                    tolerance: Self.supervisionTolerance
                )
                // Ends with its player too, not only when cancelled.
                guard !Task.isCancelled, let self else { break }
                self.superviseTick()
            }
        }
    }

    private func superviseTick() {
        guard playbackMode == .stream else { return }
        if liveAttemptID != nil {
            sampleLivePlayback()
        } else {
            apply(supervisor.tick(at: Self.now))
        }
    }

    private func networkRestored() {
        // Requests held through the outage try again now, not at their
        // next interval.
        holdProxy.networkRestored()
        guard playbackMode == .stream else { return }
        apply(supervisor.networkBecameAvailable(at: Self.now))
    }

    /// Mirrors the supervisor's display into `state` / `isRetrying`,
    /// assigning only on change so the periodic look does not re-render
    /// SwiftUI every second.
    private func publishLiveState() {
        guard playbackMode == .stream,
              let station = currentStation,
              let display = supervisor.display
        else { return }
        let newState: PlaybackState = display == .playing
            ? .playing(station.title) : .connecting(station.title)
        let retrying = display == .retrying
        if state != newState { state = newState }
        if isRetrying != retrying { isRetrying = retrying }
    }

    /// Cancels every live timer, pending retry and attempt. After this no
    /// callback, tick or network change can restart the audio.
    private func stopLiveSupervision() {
        supervisor.stop()
        supervisionTask?.cancel()
        supervisionTask = nil
        liveAttemptID = nil
        liveAttemptError = nil
        if isRetrying { isRetrying = false }
        backgroundKeeper.setRunning(false)
    }

    /// Reports the first round of a play request in which every stream
    /// failed — once per request, not once per retry round.
    private func reportStreamFailure() {
        let error = liveAttemptError
            ?? LiveStreamFailure(supervisor.lastGiveUpReason)
        reportError(
            error,
            "avplayer_stream_failed",
            [
                "station_slug": currentStation?.slug ?? "?",
                "stream_count": streams.count,
                "last_attempted_url": lastAttemptedStreamUrl ?? "?"
            ]
        )
    }

    // MARK: - System pauses

    /// Acts on the system pausing the audio (see `SystemPlaybackEvents`).
    /// Internal rather than private so tests can drive it.
    func handleSystemEvent(_ event: SystemPlaybackEvents.Event) {
        switch event {
        case .interruptionBegan:
            guard wantsToPlay else { return }
            pausePlayback()
            resumesAfterInterruption = true
        case .interruptionEnded(let shouldResume):
            let resume = resumesAfterInterruption && shouldResume
            resumesAfterInterruption = false
            if resume, case .paused = state { resumePlayback() }
        case .outputLost:
            guard wantsToPlay else { return }
            resumesAfterInterruption = false
            pausePlayback()
        case .pausedInBackground:
            guard wantsToPlay, player.rate == 0 else { return }
            pausePlayback()
        }
    }

    // MARK: - Item plumbing

    /// Drops the current item and everything observing it, closing its
    /// connection.
    private func detachCurrentItem() {
        itemObserver?.cancel()
        itemObserver = nil
        dateRangeCollector = nil
        dateRangeBridge = nil
        songChangeWaits.values.forEach { $0.cancel() }
        songChangeWaits = [:]
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStreamType = nil
    }

    private func observePlayer() {
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor in self?.sampleLivePlayback() }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor in self?.sampleLivePlayback() }
            },
        ]
    }

    // MARK: - Playlist playback

    /// Load and observe the playlist item at `index`. Sets up the VOD time
    /// observer; the item observer drives auto-advance at its end.
    private func loadPlaylistItem(at index: Int) {
        guard index >= 0, index < playlistItems.count else { return }
        // Silence the previous item first, so a late failure of it cannot
        // spend the error budget again.
        itemObserver?.cancel()
        itemObserver = nil
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
        // VOD: let AVPlayer choose the buffer (0 = automatic). The live cap
        // is sized to the live window; an on-demand file has no live edge,
        // and AVPlayer's own choice keeps it from stalling.
        item.preferredForwardBufferDuration = 0
        itemObserver = PlayerItemObserver(item: item) { [weak self] event in
            self?.handlePlaylistItemEvent(event)
        }
        player.replaceCurrentItem(with: item)
        addTimeObserver()
    }

    private func handlePlaylistItemEvent(_ event: PlayerItemObserver.Event) {
        guard playbackMode == .playlist else { return }
        switch event {
        case .readyToPlay:
            // Only a connecting item turns "playing": one the listener
            // paused before it was ready stays paused.
            if case .connecting(let title) = state {
                state = .playing(title)
            }
            // A clean start clears the broken-playlist error budget.
            consecutivePlaylistErrors = 0
        case .failed(let error), .failedToPlayToEnd(let error):
            // Both mean this item cannot play on; a file that breaks off
            // mid-way reports only `failedToPlayToEnd`.
            if let error {
                reportError(
                    error,
                    "avplayer_playlist_item_failed",
                    [
                        "station_slug": currentStation?.slug ?? "?",
                        "item_index": playlistIndex
                    ]
                )
            }
            advancePlaylistItem(dueToError: true)
        case .playedToEnd:
            advancePlaylistItem(dueToError: false)
        }
    }

    /// Advance to the next item, looping at the end. When `dueToError` and
    /// every item has failed in a row, stop instead of looping forever.
    private func advancePlaylistItem(dueToError: Bool) {
        guard !playlistItems.isEmpty else { return }
        if dueToError {
            consecutivePlaylistErrors += 1
            if consecutivePlaylistErrors >= playlistItems.count {
                state = .failed("Nu am putut reda playlistul")
                itemObserver?.cancel()
                itemObserver = nil
                removeTimeObserver()
                return
            }
        }
        let next = playlistIndex + 1
        loadPlaylistItem(at: next < playlistItems.count ? next : 0)
        player.play()
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
        removeTimeObserver()
        playlistItems = []
        playlistIndex = 0
        playlistCount = 0
        currentPlaylistItem = nil
        consecutivePlaylistErrors = 0
        vodPosition = 0
        vodDuration = 0
        unplayableOnlyPlaylist = false
        playlistDepleted = false
    }

    /// Wire an `AVPlayerItemMetadataCollector` onto the new item so the
    /// server's `EXT-X-DATERANGE` entries surface in-app. Additive to the
    /// periodic metadata REST poll — early-trigger only, never replaces.
    private func attachDateRangeCollector(to item: AVPlayerItem) {
        // Reset so the first DATERANGE on the new stream registers as a
        // change rather than colliding with the previous stream's ID.
        lastSeenDateRangeID = nil
        let bridge = DateRangeBridge { [weak self, weak item] newID, start in
            Task { @MainActor in
                // Announcements of a replaced item say nothing about the
                // audio now playing.
                guard let self, let item,
                      self.player.currentItem === item else { return }
                guard newID != self.lastSeenDateRangeID else { return }
                self.lastSeenDateRangeID = newID
                self.notifyWhenAudioReaches(songStart: start, id: newID,
                                            on: item)
            }
        }
        let collector = AVPlayerItemMetadataCollector()
        collector.setDelegate(bridge, queue: .main)
        item.add(collector)
        dateRangeBridge = bridge
        dateRangeCollector = collector
    }

    /// Fires `onAudioReachedSongChange` once the audio is past a song
    /// change announced to start at `songStart`.
    ///
    /// The collector reports a tag when it loads it, as the tag enters the
    /// playlist at the live edge — 18–30 s before the listener hears that
    /// moment. A fetch at the announcement asked for the moment the audio
    /// was at, which was still the old song, and the title stayed one song
    /// behind until the next announcement. The wait ends once the 10 s-
    /// rounded timestamp the fetch sends (`hlsPlaybackTimestamp`) is past
    /// the change, so the fetch returns the new song.
    private func notifyWhenAudioReaches(
        songStart: Date,
        id: String,
        on item: AVPlayerItem
    ) {
        let target = nextRoundedMoment(after: songStart)
        songChangeWaits[id] = Task { [weak self, weak item] in
            while true {
                guard let wait = self?.secondsUntil(item, plays: target)
                else { return }
                if wait <= 0 { break }
                try? await Task.sleep(
                    for: .seconds(max(wait, Self.songChangeRecheck))
                )
                if Task.isCancelled { return }
            }
            self?.songChangeWaits[id] = nil
            self?.onAudioReachedSongChange?()
        }
    }

    /// Seconds until `item`'s playhead reaches `target` on the broadcast
    /// timeline (zero or less once it has); nil once the item no longer
    /// plays. A playhead without a date yet is looked at again later.
    private func secondsUntil(
        _ item: AVPlayerItem?,
        plays target: Date
    ) -> TimeInterval? {
        guard let item, player.currentItem === item else { return nil }
        guard let heard = Self.playheadDate(of: item) else {
            return Self.songChangeRecheck
        }
        return target.timeIntervalSince(heard)
    }

    /// The station's live streams that have a usable URL, in API order.
    private static func resolvedStreams(
        of station: Station
    ) -> [ResolvedStream] {
        station.orderedStreams.compactMap { stream in
            trackedURL(for: stream.streamUrl).map {
                ResolvedStream(source: stream, url: $0)
            }
        }
    }

    // MARK: - Stream URL tracking

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
        items.append(URLQueryItem(name: "s", value: DeviceIdentity.deviceId))
        components.queryItems = items
        return components.url ?? baseURL
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

    /// The listener's intent: true while connecting (a pending retry
    /// included) or playing. Unlike `isPlaying`, it stays true while the
    /// engine brings a station back, so the UI and remote commands can tell
    /// it apart from one the listener paused.
    var wantsToPlay: Bool {
        switch state {
        case .connecting, .playing:
            return true
        case .idle, .paused, .failed:
            return false
        }
    }
}

// MARK: - Live stream failures

/// Why the engine gave up on a live stream, reported to analytics in place
/// of an AVFoundation error when AVPlayer supplied none.
private enum LiveStreamFailure: LocalizedError {
    case noStart
    case stalled
    case stale
    case ended
    case unknown

    init(_ reason: LiveStreamSupervisor.GiveUpReason?) {
        switch reason {
        case .noStart: self = .noStart
        case .stalled: self = .stalled
        case .stale: self = .stale
        case .failed, nil: self = .unknown
        }
    }

    var errorDescription: String? {
        switch self {
        case .noStart:
            return "The stream did not start within the connect timeout"
        case .stalled:
            return "The stream stopped advancing for the stall timeout"
        case .stale:
            return "The HLS playlist stopped advancing (its audio is old)"
        case .ended:
            return "The server ended the live stream"
        case .unknown:
            return "AVPlayer reported a failure without an error"
        }
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
    /// Called with the newest announced group's `ID` and start date.
    private let onNewID: (String, Date) -> Void

    init(onNewID: @escaping (String, Date) -> Void) {
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
        guard let latest else { return }
        onNewID(latest.id, latest.date)
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
