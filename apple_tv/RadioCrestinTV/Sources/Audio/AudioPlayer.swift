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
///   * `followsHlsAudio` / `hlsHeardDate` — whether the song shown follows
///     the HLS audio, and where on the broadcast timeline the listener is,
///     also while the station connects again or is paused.
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

    /// What the current live attempt loads, and what its reloads found out.
    private struct LiveLoad {
        let stream: ResolvedStream
        /// The stream's URL, or its start variant.
        let url: URL
        /// Whether `url` is the stream's start variant, which starts
        /// `seekMode`'s offset behind live.
        let isStartVariant: Bool
        /// The hold proxy session the item loads through; nil when it
        /// loads directly.
        var proxySession: Int?
        /// The origin did not find the start variant, and the stream's own
        /// playlist loads instead. Once that loads, the stream skips its
        /// variant from now on. Had it failed too, the network or the
        /// stream would explain both (a pod restarting, a dropped signal),
        /// and the next load tries the variant again, as the phone does.
        var variantIsMissing = false
        /// The load through the hold proxy failed for the proxy's own sake,
        /// and the URL loads directly instead. Once that loads, the stream
        /// skips the proxy until the network comes back or changes. Had it
        /// failed too, the network or the origin would explain both.
        var bypassesHoldProxy = false

        /// How far behind live the item starts on purpose.
        func joinOffset(in mode: SeekMode) -> TimeInterval {
            isStartVariant ? mode.offset : 0
        }
    }

    /// The live station's streams that have a usable URL, in API order
    /// (HLS first, then the direct MP3/AAC stream).
    private var streams: [ResolvedStream] = []

    /// Decides when a live stream has failed and what to try next.
    private var supervisor = LiveStreamSupervisor()

    /// The supervisor's attempt whose item AVPlayer holds; nil while waiting
    /// to retry and whenever no live stream is wanted.
    private var liveAttemptID: Int?

    /// What `liveAttemptID` loads; nil with it.
    private var liveLoad: LiveLoad?

    /// The live attempt whose audio start was announced
    /// (`onLiveAudioStarted`), so that a stall the same item recovers from
    /// is not announced again.
    private var startedAttempt: Int?

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

    /// The HLS origin's hosts (`HlsStartVariant.hosts`): only their radio
    /// streams have start variants and load through the hold proxy.
    private let originHosts: Set<String>

    /// The remote kill switch of the hold proxy (`HlsHoldProxyFlag`).
    private let isHoldProxyEnabled: () -> Bool

    /// Holds the origin's radio HLS requests through a network outage, so
    /// AVPlayer plays it out from its forward buffer instead of giving up
    /// on the stream (see `HlsHoldProxy`).
    private let holdProxy: HlsHoldProxy

    /// Holds are rare (an outage), so each event is logged.
    private nonisolated static let holdProxyLog = Logger(
        subsystem: "ro.radiocrestin.tv", category: "HlsHoldProxy"
    )

    /// Streams whose start variant the origin does not publish: they start
    /// at their own playlist for the rest of the app's run.
    private var streamsWithoutVariant: Set<String> = []

    /// Streams that played directly after their load through the hold
    /// proxy failed for the proxy's own sake: they skip it until the
    /// network comes back or changes. Mirrors the phone's
    /// `_streamsWithoutHoldProxy`.
    private var streamsWithoutHoldProxy: Set<String> = []

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

    /// The current station's radio HLS stream, as long as it is what the
    /// listener hears or, paused or waiting to try again, hears next: a
    /// resume or a reconnect loads the same URL, which starts at the same
    /// offset behind live. Nil once a direct stream (MP3/AAC), heard live,
    /// plays.
    private var hlsListening: HlsListening?

    /// A radio HLS stream the listener hears, and how far behind live.
    private struct HlsListening {
        /// The URL loaded: the stream's start variant or its own playlist.
        /// Another URL starts at another offset.
        let url: URL
        /// Now minus the playhead's PROGRAM-DATE-TIME, the last time the
        /// stream was looked at while it played; nil until it played.
        var lag: TimeInterval?
        /// Where on the broadcast timeline the listener paused, until the
        /// stream plays again: the song shown stays the one heard, as in
        /// Apple Music.
        var pausedAt: Date?
    }

    /// Where the listener paused the current radio station's direct stream
    /// (MP3/AAC). Heard live, the audio stopped at that moment, and the
    /// song shown stays the one heard, as for HLS
    /// (`HlsListening.pausedAt`). Kept until a stream of the station plays
    /// (`publishLiveState`), another station plays or the player stops: a
    /// resume or a retry still connecting has not been heard, and a pause
    /// then keeps the first moment.
    private(set) var directStreamPausedAt: Date?

    /// Where the current station's audio stopped, while nothing has been
    /// heard since: paused, or a resume or retry still connecting. Nil
    /// while a stream plays, and before one has played.
    var stoppedAt: Date? {
        hlsListening?.pausedAt ?? directStreamPausedAt
    }

    /// The song changes the current radio HLS item's playlist announced
    /// with `EXT-X-DATERANGE`. Reset on item swap.
    private var songBoundaries = SongBoundaries()

    /// Bridge for `AVPlayerItemMetadataCollector` — the collector requires
    /// an `NSObjectProtocol` delegate, which `AudioPlayer` is not.
    private var dateRangeCollector: AVPlayerItemMetadataCollector?
    private var dateRangeBridge: DateRangeBridge?

    /// Fired when the audio reaches a song change the HLS playlist
    /// announced with `EXT-X-DATERANGE`, within a second of it, so an
    /// audio-aligned metadata fetch (`hlsPlaybackTimestamp`) now gets the
    /// new song. Wired by `PlaybackCoordinator`, additive to the periodic
    /// `/stations-metadata` poll.
    var onAudioReachedSongChange: (() -> Void)?

    /// Fired when the audio of a live item starts playing: a tune-in, a
    /// resume, a seek-mode change, a recovery or the fallback to another
    /// stream. From then on the song the listener hears is known (the
    /// playhead's `EXT-X-PROGRAM-DATE-TIME`, or live for MP3/AAC), so it
    /// is fetched at once. Not again when the same item recovers from a
    /// stall: its audio goes on where it was, and a flapping connection
    /// must not flood the API.
    var onLiveAudioStarted: (() -> Void)?

    /// `originHosts`: the hosts of the HLS origin, whose radio streams have
    /// start variants and load through the hold proxy.
    /// `isHoldProxyEnabled`: the hold proxy's remote kill switch.
    init(
        repository: StationRepository = StationRepository(),
        reportError: @escaping ErrorReporter = {
            Analytics.captureError($0, context: $1, extra: $2)
        },
        originHosts: Set<String> = HlsStartVariant.hosts,
        isHoldProxyEnabled: @escaping () -> Bool = {
            HlsHoldProxyFlag.isEnabled
        }
    ) {
        self.repository = repository
        self.reportError = reportError
        self.originHosts = Set(originHosts.map { $0.lowercased() })
        self.isHoldProxyEnabled = isHoldProxyEnabled
        holdProxy = HlsHoldProxy(
            allowedHosts: originHosts,
            onEvent: { event in
                AudioPlayer.holdProxyLog.notice(
                    "\(event.description, privacy: .public)"
                )
            }
        )
        // Active audio session so the player keeps running when the
        // user backgrounds the app via Home button on the Siri Remote.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: []
        )
        // Off the main thread: activating waits on the system's audio
        // server, which the runtime flagged at every launch as a hang risk
        // for the UI. A play before it is done activates the session
        // itself.
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
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
        networkWatcher.onChanged = { [weak self] in
            self?.networkChanged()
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
        // Another station is heard at another distance behind live, and
        // was not paused.
        if station.id != currentStation?.id {
            hlsListening = nil
            directStreamPausedAt = nil
        }
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
                // the one terminal failure for a live station. Worded as
                // on the phone's CarPlay screen.
                state = .failed("Nu s-a putut conecta la post")
                return
            }
            state = .connecting(station.title)
            apply(supervisor.start(streamCount: streams.count, at: Self.now))
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
        hlsListening = nil
        directStreamPausedAt = nil
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
        // The next load starts at the new offset, paused or not: how far
        // behind live the last one was heard says nothing about it.
        hlsListening?.lag = nil
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
            // Read first: the optional chain below starts changing
            // `hlsListening` before its right side runs, and reading it
            // then is an exclusivity violation.
            let heardAt = hlsHeardDate
            hlsListening?.pausedAt = heardAt
            // Nothing was heard since a moment still kept: a pause while a
            // resume connects stays where the audio stopped.
            if hlsListening == nil, station.kind == .radio,
               directStreamPausedAt == nil {
                directStreamPausedAt = Date()
            }
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

    /// Whether the current station's song follows its audio rather than the
    /// live timeline: its live stream — playing, connecting, paused or
    /// waiting to try again — is radio HLS, played behind live, and no
    /// direct stream of a retry round has started to play instead.
    var followsHlsAudio: Bool { hlsListening != nil }

    /// The broadcast moment the listener hears on the current station's
    /// radio HLS stream: the playhead's date while it plays; paused, the
    /// moment it was paused at, until a stream plays again (a resumed item
    /// whose playhead the engine has not taken as playing included); while
    /// it connects again or waits to retry, as far behind live as it was
    /// last heard, since a reconnect loads the same stream at the same
    /// offset. Nil before the stream has played, and for a direct stream.
    ///
    /// A paused clock that moved on with live let a full refresh (back to
    /// the app, the 10 minute one) put a song the listener never heard on
    /// screen and in the system's Now Playing.
    var hlsHeardDate: Date? {
        if let pausedAt = hlsListening?.pausedAt { return pausedAt }
        if let date = hlsPlaybackDate { return date }
        guard let listening = hlsListening else { return nil }
        return listening.lag.map { Date().addingTimeInterval(-$0) }
    }

    /// 10s-aligned Unix timestamp of the audio currently being heard for
    /// the active HLS stream, suitable as the `?timestamp=` parameter on
    /// `/api/v1/stations-metadata`. Returns nil for non-HLS streams or
    /// before the playlist has been parsed.
    ///
    /// Rounded down, except in the 10 s after a song change the audio has
    /// reached: then it is the first rounded moment after the change. The
    /// API answers with the song playing at the timestamp, to the second,
    /// so the fetch the change triggers gets the song that just started
    /// rather than the one that ended, without waiting up to 10 s for the
    /// audio to reach the next rounded moment.
    ///
    /// Gated to radio stations: TV video streams may also be HLS, but their
    /// now-playing song metadata isn't offset-synced, so they must not drive
    /// the audio-aligned metadata fetch.
    var hlsPlaybackTimestamp: Int? {
        guard let heard = hlsPlaybackDate else { return nil }
        let timestamp = roundedTimestamp(at: heard)
        guard let change = songBoundaries.latest(atOrBefore: heard) else {
            return timestamp
        }
        let afterChange = roundedTimestamp(at: nextRoundedMoment(after: change))
        return max(timestamp, afterChange)
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
            liveLoad = nil
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
        liveLoad = LiveLoad(
            stream: stream,
            url: variant ?? stream.url,
            isStartVariant: variant != nil
        )
        loadLiveItem(attempt: attempt)
    }

    /// Loads the URL of live `attempt` (`liveLoad`), through the hold proxy
    /// when it applies, directly otherwise.
    private func loadLiveItem(attempt: Int) {
        guard let load = liveLoad else { return }
        currentStreamType = load.stream.source.type
        followListening(to: load)
        guard usesHoldProxy(load) else {
            attachLiveItem(url: load.url, attempt: attempt)
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
            let session = isRunning ? proxy.beginSession() : nil
            let proxied = session.flatMap { proxy.wrap(load.url, session: $0) }
            if proxied != nil { self.liveLoad?.proxySession = session }
            self.attachLiveItem(url: proxied ?? load.url, attempt: attempt)
        }
    }

    /// Points `hlsListening` at the stream `load` brings. How far behind live
    /// the listener heard the same URL holds for it again (a resume, a
    /// retry); another HLS URL starts elsewhere. A direct stream is heard
    /// live only once it plays (`publishLiveState`): until then the
    /// listener still hears, or waits to hear again, the HLS stream, which
    /// the next attempt may well be. Dropping it at once let the title
    /// jump to the live song during a retry round, then back.
    ///
    /// Resumed after a pause, on another URL (another offset, the stream's
    /// own playlist) or after the MP3 fallback, the HLS attempt holds where
    /// the audio stopped until it plays: the song and "Melodii recente"
    /// went to its assumed offset at the press, a moment the listener
    /// never heard.
    private func followListening(to load: LiveLoad) {
        guard currentStation?.kind == .radio,
              load.stream.source.type == "HLS",
              hlsListening?.url != load.url
        else { return }
        hlsListening = HlsListening(
            url: load.url,
            pausedAt: hlsListening?.pausedAt ?? directStreamPausedAt
        )
    }

    private func attachLiveItem(url: URL, attempt: Int) {
        // The offset of the item loaded, not the setting's: a stream
        // without its variant joins live, and its stale-playlist check
        // must not allow for minutes it does not start behind.
        let joinOffset = liveLoad?.joinOffset(in: seekMode) ?? 0
        supervisor.setJoinOffset(joinOffset, attempt: attempt)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = liveForwardBuffer(
            startsBehindLive: joinOffset
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
        return HlsStartVariant.url(
            for: stream.url, mode: seekMode, origin: originHosts
        )
    }

    /// Whether `load` goes through the hold proxy: radio HLS of the origin,
    /// the remote kill switch on, unless the proxy failed for its stream.
    private func usesHoldProxy(_ load: LiveLoad) -> Bool {
        let stream = load.stream
        return currentStation?.kind == .radio
            && stream.source.type == "HLS"
            && !load.bypassesHoldProxy
            && !streamsWithoutHoldProxy.contains(stream.source.streamUrl)
            && isHoldProxyEnabled()
            && stream.url.host.map {
                originHosts.contains($0.lowercased())
            } ?? false
    }

    /// The origin answered the attempt's start variant with "not found":
    /// it does not publish one for this stream (not deployed there yet),
    /// or it briefly answers so for everything (a pod restarting). The
    /// stream's own playlist loads at once, in the same attempt: that is no
    /// stream failure, the stream itself may well be fine.
    private func loadOwnPlaylist(attempt: Int) {
        guard let load = liveLoad else { return }
        var own = LiveLoad(
            stream: load.stream, url: load.stream.url, isStartVariant: false
        )
        own.variantIsMissing = true
        own.bypassesHoldProxy = load.bypassesHoldProxy
        liveLoad = own
        detachCurrentItem()
        loadLiveItem(attempt: attempt)
    }

    /// Loads the attempt's URL again at once, directly: its load through
    /// the hold proxy failed for the proxy's own sake. That is no stream
    /// failure: without the proxy the stream may well play, and it gets a
    /// full connect timeout to do so.
    private func bypassHoldProxy(attempt: Int) {
        guard var load = liveLoad else { return }
        load.proxySession = nil
        load.bypassesHoldProxy = true
        liveLoad = load
        detachCurrentItem()
        supervisor.restartAttempt(attempt, at: Self.now)
        loadLiveItem(attempt: attempt)
    }

    /// The hold proxy session the attempt's item loads through, unless the
    /// device is known to be offline: no load works then, through the proxy
    /// or not, so a failure says nothing about the proxy.
    private var proxySessionWhileOnline: Int? {
        networkWatcher.isSatisfied == false ? nil : liveLoad?.proxySession
    }

    /// The item loaded: what the attempt's reloads found out holds for its
    /// stream from now on.
    private func rememberWhatTheReloadsFoundOut() {
        guard let load = liveLoad else { return }
        let stream = load.stream.source.streamUrl
        if load.variantIsMissing { streamsWithoutVariant.insert(stream) }
        if load.bypassesHoldProxy { streamsWithoutHoldProxy.insert(stream) }
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
            rememberWhatTheReloadsFoundOut()
            // A ready item can make a `.playing` reading count.
            sampleLivePlayback()
            followSongBoundaries()
        case .failed(let error):
            if liveLoad?.isStartVariant == true, Self.isNotFound(error) {
                loadOwnPlaylist(attempt: attempt)
                return
            }
            // Through the hold proxy, before the origin answered any of
            // its requests (an HTTP status, an error one included, is an
            // answer): the proxy's way failed, not the stream.
            if let session = proxySessionWhileOnline,
               !holdProxy.originAnswered(session: session) {
                bypassHoldProxy(attempt: attempt)
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
        let now = Self.now
        // A load through the hold proxy that has not started, and none of
        // whose requests even went upstream: the proxy holds it up. One
        // that did and still waits says the origin is slow or out of
        // reach, which a direct load would meet as well.
        if supervisor.hasMissedConnectTimeout(attempt, at: now),
           let session = proxySessionWhileOnline,
           !holdProxy.originRequested(session: session) {
            bypassHoldProxy(attempt: attempt)
            return
        }
        let time = player.currentTime().seconds
        let audioDate = player.currentItem.flatMap(Self.playheadDate(of:))
        let liveLag = audioDate.map { Date().timeIntervalSince($0) }
        let sample = LiveStreamSupervisor.Sample(
            status: .init(
                timeControlStatus: player.timeControlStatus,
                waitingReason: player.reasonForWaitingToPlay,
                itemIsReady: player.currentItem?.status == .readyToPlay
            ),
            playhead: time.isFinite ? time : nil,
            liveLag: liveLag
        )
        apply(supervisor.record(sample, attempt: attempt, at: now))
        // Only while it plays, as the supervisor takes it: a stall does not
        // move the offset a reconnect or a resume rejoins the stream at,
        // and a join it turns down as stale is not heard. Taken before its
        // verdict, a stale join's lag moved the song shown minutes back
        // and dropped the moment a pause had kept.
        if isPlayingHls, liveAttemptID == attempt,
           supervisor.display == .playing,
           player.timeControlStatus == .playing, let liveLag {
            hlsListening?.lag = liveLag
            hlsListening?.pausedAt = nil
        }
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
            followSongBoundaries()
        } else {
            apply(supervisor.tick(at: Self.now))
        }
    }

    /// The network path became usable again (`NetworkPathWatcher`).
    /// Internal rather than private so tests can drive it.
    func networkRestored() {
        // Requests held through the outage try again now, not at their
        // next interval.
        holdProxy.networkRestored()
        // The proxy may work on the network that came back.
        streamsWithoutHoldProxy.removeAll()
        guard playbackMode == .stream else { return }
        apply(supervisor.networkBecameAvailable(at: Self.now))
    }

    /// The device moved to another network interface and stayed online:
    /// the proxy's requests in flight on the interface it left are cut and
    /// tried again at once on the new one, and the proxy may work there for
    /// the streams it failed. A wait to retry ends now, as when the network
    /// comes back: the failures were most likely the network's. Internal
    /// rather than private so tests can drive it.
    func networkChanged() {
        holdProxy.networkChanged()
        streamsWithoutHoldProxy.removeAll()
        guard playbackMode == .stream else { return }
        apply(supervisor.networkBecameAvailable(at: Self.now))
    }

    /// Mirrors the supervisor's display into `state` / `isRetrying`,
    /// assigning only on change so the periodic look does not re-render
    /// SwiftUI every second. Announces the start of each attempt's audio
    /// (`onLiveAudioStarted`).
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
        if display == .playing {
            directStreamPausedAt = nil
            // A direct stream plays: the listener hears live from now on.
            if !isPlayingHls { hlsListening = nil }
        }
        if display == .playing, let attempt = liveAttemptID,
           attempt != startedAttempt {
            startedAttempt = attempt
            onLiveAudioStarted?()
        }
    }

    /// Cancels every live timer, pending retry and attempt. After this no
    /// callback, tick or network change can restart the audio.
    private func stopLiveSupervision() {
        supervisor.stop()
        supervisionTask?.cancel()
        supervisionTask = nil
        liveAttemptID = nil
        liveLoad = nil
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
        songBoundaries = SongBoundaries()
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
    /// song changes its playlist announces with `EXT-X-DATERANGE` reach
    /// `songBoundaries`. Additive to the periodic metadata REST poll.
    private func attachDateRangeCollector(to item: AVPlayerItem) {
        let bridge = DateRangeBridge { [weak self, weak item] boundaries in
            Task { @MainActor in
                // Announcements of a replaced item say nothing about the
                // audio now playing.
                guard let self, let item,
                      self.player.currentItem === item else { return }
                self.songBoundaries.add(boundaries)
                // One the audio already passed counts at once.
                self.followSongBoundaries()
            }
        }
        let collector = AVPlayerItemMetadataCollector()
        collector.setDelegate(bridge, queue: .main)
        item.add(collector)
        dateRangeBridge = bridge
        dateRangeCollector = collector
    }

    /// Fires `onAudioReachedSongChange` when the audio has reached a song
    /// change since its start. Called on each look at the player, so within
    /// a second of the change: the fetch it triggers then asks about the
    /// moment right after it (`hlsPlaybackTimestamp`) and gets the new song.
    ///
    /// The collector reports a tag when it loads it, as the tag enters the
    /// playlist at the live edge, and the origin writes it once the song
    /// ended: its end date is still ahead of a listener 18 s to 5 minutes
    /// behind live. A fetch at the announcement asked about the moment the
    /// audio was at, still the old song.
    private func followSongBoundaries() {
        guard let heard = hlsPlaybackDate else { return }
        if songBoundaries.reach(heard) { onAudioReachedSongChange?() }
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
///
/// Hands over the start and end dates of each group announced or changed,
/// every one a song boundary (see `SongBoundaries`). The dates are all
/// there is to go by: AVFoundation gives a group's `X-` attributes as its
/// items (`lsdr/X-TITLE`, `lsdr/X-ARTIST`), never its `ID` (measured with
/// macOS 27's AVFoundation on the origin's playlists, 2026-10-31).
private final class DateRangeBridge: NSObject,
    AVPlayerItemMetadataCollectorPushDelegate {
    /// Called with the boundaries of the groups announced or changed.
    private let onBoundaries: ([Date]) -> Void

    init(onBoundaries: @escaping ([Date]) -> Void) {
        self.onBoundaries = onBoundaries
        super.init()
    }

    func metadataCollector(
        _ metadataCollector: AVPlayerItemMetadataCollector,
        didCollect metadataGroups: [AVDateRangeMetadataGroup],
        indexesOfNewGroups: IndexSet,
        indexesOfModifiedGroups: IndexSet
    ) {
        var boundaries: [Date] = []
        for index in indexesOfNewGroups.union(indexesOfModifiedGroups)
        where index < metadataGroups.count {
            let group = metadataGroups[index]
            boundaries.append(group.startDate)
            if let end = group.endDate { boundaries.append(end) }
        }
        guard !boundaries.isEmpty else { return }
        onBoundaries(boundaries)
    }
}
