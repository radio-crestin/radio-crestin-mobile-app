import Foundation
import SwiftUI

/// Why a metadata sync was requested. Drives the choice between full
/// refresh, audio-aligned offset diff, and live-timeline diff. Listed in
/// priority order — when multiple reasons coalesce while a sync is in
/// flight, the lower raw value (= higher priority) wins, its work covering
/// theirs. `audioMetadataChanged` never coalesces (see `enqueueSync`).
/// Mirrors the Dart `SyncReason` enum in `station_data_service.dart`.
enum SyncReason: Int {
    case startup = 0
    case appResumed = 1
    case stationPlayed = 2
    case seekOffsetChanged = 3
    case audioMetadataChanged = 4
    case periodic = 5
}

/// The station lists the tabs show. Each keeps its own on-screen order
/// (see `StationOrder`).
enum StationList: Hashable, CaseIterable {
    /// "Posturi": every station, ranked by the chosen sort.
    case all
    case favorites
    case recents
}

/// App-wide state, scoped to the lifetime of the SwiftUI App. Holds the
/// station list (loaded from the REST `/stations` endpoint, and at launch
/// from the last catalog saved, see `StationCatalogCache`), favorites
/// (persisted in UserDefaults), recents (also persisted), and the
/// current selection driving Now Playing.
///
/// Owns the **unified metadata sync engine**: a single `enqueueSync(reason)`
/// entry point coalesces every refresh trigger (startup, app-resume,
/// station-play, seek-offset, audio-metadata, periodic). A 60s wall-clock
/// tick (15 s while a direct stream plays) keeps the visible station list
/// fresh; HLS DATERANGE events drive
/// out-of-cycle audio-aligned diffs for the playing station; full refresh
/// fires on play / resume / seek-offset / 10-min window. Mirrors the
/// Flutter `StationDataService` contract.
///
/// Keeping a single observable holder avoids passing 4-5 bindings down
/// the view tree.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Inputs
    private let repository: StationRepository
    private let defaults: UserDefaults
    private let catalogCache: StationCatalogCache

    /// Reports that the listener moved from one station (nil: none) to
    /// another.
    typealias ListeningReporter = @MainActor (_ from: Station?, _ to: Station) -> Void
    private let reportListening: ListeningReporter

    // MARK: - Published state
    @Published private(set) var stations: [Station] = []
    @Published private(set) var isLoading = false
    /// Why the catalog failed to load, in words for the listener (see
    /// `loadErrorMessage(for:)`). Shown only while there is no catalog.
    @Published private(set) var loadError: String?

    @Published private(set) var favorites = FavoriteList()
    @Published private(set) var recentSlugs: [String] = []
    @Published private(set) var playCounts: [String: Int] = [:]
    @Published var sortOption: StationSort = .recommended {
        didSet {
            defaults.set(sortOption.rawValue, forKey: Keys.sort)
            refreshOrder(of: .all)
        }
    }

    /// How far behind live radio plays ("Încărcare în avans"). The player
    /// follows it through `PlaybackCoordinator`.
    @Published var seekMode: SeekMode = .default {
        didSet { defaults.set(seekMode.rawValue, forKey: Keys.seekMode) }
    }

    @Published var currentStation: Station?
    let songHistory = SongHistoryStore()

    /// True while the listener has the current station paused. Set by
    /// `PlaybackCoordinator` only when a pause or a resume changes it, so
    /// the grids that mark the current station redraw for that alone.
    @Published var isPlaybackPaused = false {
        // Paused before its audio played, a station's song is not on its
        // way: Now Playing names the station.
        didSet { if isPlaybackPaused { isAwaitingSong = false } }
    }

    /// True from a tune-in that cannot tell yet which song the listener
    /// will hear until the song shows or the audio's moment is known: an
    /// HLS station heard minutes behind live whose live song changed
    /// within those minutes, before its history or its audio tell which
    /// side of the change the audio starts on. Now Playing then names the
    /// station in its line and leaves the title empty. It showed the
    /// station's name as the title, then the song a moment later, and the
    /// station line moved as the name went into it.
    @Published private(set) var isAwaitingSong = false

    // MARK: - On-screen order

    /// The order each list was last ranked in. A list without an entry
    /// (before the first catalog load) shows its live ranking.
    @Published private(set) var listOrders: [StationList: StationOrder] = [:]

    /// Station ids of the grid the current station was opened from, in
    /// the order it showed. "Postul anterior / următor" and the remote's
    /// previous / next track walk it, so stepping never chases a list
    /// that re-ranks itself after each play.
    private var browsingOrder: [Int] = []

    /// Set once the session's first catalog is on screen: the one saved
    /// by the last launch, or else the first that loads. That is the
    /// first boundary at which the list orders are fixed.
    private var hasLoadedCatalog = false

    // MARK: - Private stations

    /// Last successfully fetched private stations for this device. The
    /// public `/stations` and `/stations-metadata` endpoints do not cover
    /// them, so this payload is both their catalog entry AND their only
    /// `now_playing`/`uptime`/listeners source. Kept across transient
    /// fetch failures so private stations never flicker out of the list,
    /// and persisted to UserDefaults so the next launch renders them
    /// instantly before any network round-trip.
    private var privateStations: [Station] = []

    /// Ids of catalog entries that came from the private endpoint. There
    /// is no wire flag — membership is tracked by fetch source. Drives
    /// the pinned-first ordering in `sortedStations`.
    private(set) var privateStationIds: Set<Int> = []

    /// True once this session learned the device has no private stations
    /// (confirmed-empty response) or the endpoint isn't deployed (404) —
    /// periodic ticks then skip the fetch so we don't reload a known-empty
    /// answer all session. Launch and app-resume always recheck.
    private var privateFetchDisabled = false

    // MARK: - Audio sync hooks (set by RootView after AudioPlayer init)

    /// Returns the 10s-aligned PROGRAM-DATE-TIME of the audio currently
    /// being heard, or nil if not playing HLS / playlist not yet parsed.
    var hlsPlaybackTimestampProvider: (() -> Int?)?

    /// Returns where on the broadcast timeline the listener of the current
    /// station's HLS stream is: the playhead's PROGRAM-DATE-TIME; paused,
    /// where it was paused; while it connects again, as far behind live as
    /// it was last heard. Nil until that is known. Decides which songs the
    /// listener has reached.
    var hlsHeardDateProvider: (() -> Date?)?

    /// True while the current station's song follows its HLS audio: its
    /// live stream, playing, connecting or paused, is radio HLS.
    var followsHlsAudioProvider: (() -> Bool)?

    /// True when the currently playing stream is HLS. Used as a fallback
    /// trigger to fetch an offset metadata payload even when the precise
    /// HLS timestamp isn't yet available.
    var isPlayingHlsProvider: (() -> Bool)?

    /// True while the current station's audio plays (not connecting,
    /// paused or failed).
    var isPlayingProvider: (() -> Bool)?

    /// Where the listener paused the current station's direct stream
    /// (MP3/AAC), kept until a stream of the station plays again: a
    /// resume still connecting has not been heard. Nil for HLS. Heard
    /// live, its song stopped there with the audio.
    var directStreamPausedAtProvider: (() -> Date?)?

    /// Where the current station's audio stopped, while nothing has been
    /// heard since: paused, or a resume or retry still connecting. Nil
    /// while a stream plays.
    var audioStoppedAtProvider: (() -> Date?)?

    // MARK: - Sync engine state

    /// Periodic 60s safety-net loop. Audio events drive the playing
    /// station's now-playing; this tick keeps the rest of the list fresh.
    private var periodicTask: Task<Void, Never>?

    /// Mutex over the sync pipeline. All paths funnel through
    /// `enqueueSync`, so a single in-flight call is enough — overlapping
    /// triggers coalesce into [pendingReason].
    private var isSyncing: Bool = false

    /// Highest-priority reason queued while a sync is in flight. Drained on
    /// completion of the current sync. `nil` means nothing pending.
    private var pendingReason: SyncReason?

    /// An audio event came while a sync was in flight. Kept apart from
    /// `pendingReason`: no other sync fetches the song at the audio's
    /// moment, so coalescing it into one dropped it.
    private var isAudioEventPending = false

    /// Live-timeline cursor (Unix seconds, 10s-rounded). Sent as
    /// `changes_from_timestamp` on the next live diff.
    private var lastFetchTimestamp: Int = 0

    /// Offset-timeline cursor — stores the timestamp value sent on the
    /// last offset request, not wall-clock now, so it matches the server's
    /// cache key. Reset to 0 whenever the offset frame of reference may
    /// have shifted (full refresh, error recovery, init).
    private var lastOffsetFetchTimestamp: Int = 0

    /// When the last full refresh happened. Promotes the next periodic
    /// tick to full once 10 minutes have elapsed. Internal so tests can
    /// age it.
    var lastFullRefresh: Date?

    /// Last time the audio layer reported a metadata change (DATERANGE,
    /// timed metadata) whose fetch the API answered. Used by the periodic
    /// safety net.
    private var lastAudioEventTime: Date?

    /// Stations whose song history is being fetched, so a second tune-in
    /// or a sync meanwhile does not ask again.
    private var songHistoryRequests: Set<String> = []

    /// Stations whose song history fetch went unanswered (the API out of
    /// reach), asked for again with each sync while the station plays.
    private var unansweredSongHistory: Set<String> = []

    /// Stations whose last song history fetch failed, answered or not. A
    /// card taking focus does not ask again, which sent a request with
    /// every focus move to an API already failing; a tune-in does.
    private var failedSongHistory: Set<String> = []

    /// The live song last added to each station's history
    /// (`recordLiveSongs`), so a merge records only the songs that changed.
    private var recordedLiveSongs: [Int: NowPlaying] = [:]

    /// Fixed cadence for the periodic safety-net poll.
    private static let periodicInterval: TimeInterval = 60

    /// The poll's cadence while a direct stream (MP3, AAC) plays: heard
    /// live, its song changes come only with the poll, and at 60 s the
    /// title ran up to a minute late.
    private static let directStreamInterval: TimeInterval = 15

    /// 10-min full-refresh window.
    private static let fullRefreshInterval: TimeInterval = 10 * 60

    /// If audio events have gone quiet this long, the next periodic tick
    /// adds an offset fetch as a safety net.
    private static let audioEventSafetyNet: TimeInterval = 5 * 60

    /// Where the live HLS playlist starts playback, before its end
    /// (`EXT-X-START:TIME-OFFSET=-18`).
    private static let liveStartBeforeEnd: TimeInterval = 18

    /// How far a playlist's end trails real time at most: a 6 s segment
    /// and its publication, which took up to 9 s on one station (133 s
    /// behind live measured in the 2 minute mode).
    private static let playlistEndDelay: TimeInterval = 15

    /// How much less than `assumedHlsLag` HLS audio can be behind live: a
    /// playlist's end may not trail real time at all, and playback can
    /// start up to a 6 s segment after its start point (116 s measured in
    /// the 2 minute mode).
    private static let assumedHlsLagSpread: TimeInterval = playlistEndDelay + 6

    /// Maximum gap (seconds) between consecutive offset-fetch timestamps
    /// before the differential is dropped. Guards against stale cursors after
    /// long pauses, app backgrounding, or shifts between the synthetic offset
    /// and the precise PROGRAM-DATE-TIME source.
    private static let maxOffsetDiffGapSeconds: Int = 60

    /// `reportListening`: PostHog's listening events in the app. Tests pass
    /// one that reports nowhere, so they can pick stations: the test host
    /// app is set up with the production analytics project.
    init(
        repository: StationRepository = StationRepository(),
        defaults: UserDefaults = .standard,
        catalogCache: StationCatalogCache = StationCatalogCache(),
        reportListening: @escaping ListeningReporter = AppState.reportToAnalytics
    ) {
        self.repository = repository
        self.defaults = defaults
        self.catalogCache = catalogCache
        self.reportListening = reportListening
        self.favorites = FavoriteList(
            defaults.stringArray(forKey: Keys.favorites) ?? []
        )
        self.recentSlugs = defaults.stringArray(forKey: Keys.recents) ?? []
        if let saved = defaults.string(forKey: Keys.sort),
           let opt = StationSort(rawValue: saved) {
            self.sortOption = opt
        }
        if let saved = defaults.string(forKey: Keys.seekMode),
           let mode = SeekMode(rawValue: saved) {
            self.seekMode = mode
        }
        if let raw = defaults.dictionary(forKey: Keys.playCounts) as? [String: Int] {
            self.playCounts = raw
        }
        // Bootstrap private stations from the persisted copy so an
        // allowlisted device sees them immediately, before any network,
        // without the songs they had then (see `Station.withoutSong`).
        // The startup full refresh replaces them with the live answer.
        if let data = defaults.data(forKey: Keys.privateStations),
           let cached = try? JSONDecoder().decode([Station].self, from: data),
           !cached.isEmpty {
            self.privateStations = cached.map(\.withoutSong)
            self.stations = withPrivate([])
        }
        // The last catalog, so the tabs show at once and stay usable
        // while the API is down. The startup full refresh replaces it.
        if let catalog = catalogCache.load() {
            stations = withPrivate(catalog)
            firstCatalogShown()
        }
    }

    deinit {
        periodicTask?.cancel()
    }

    // MARK: - Public API — every refresh path funnels through enqueueSync.

    /// Initial bootstrap. Public so the retry button and pull-to-refresh
    /// can re-issue a full refresh on demand.
    func loadStations() async {
        await enqueueSync(.startup)
    }

    /// Forces an out-of-cycle audio-aligned metadata fetch, so the song
    /// shown is the one the listener hears. The audio engine asks for it
    /// whenever a live item's audio starts (a tune-in, a resume, a
    /// recovery, the fallback to another stream) and whenever the audio
    /// reaches a song change its HLS playlist announced.
    func refreshMetadataNow() async {
        await enqueueSync(.audioMetadataChanged)
    }

    /// Single entry point for every refresh. Coalesces overlapping
    /// triggers and runs them in priority order so concurrent callers
    /// can fire and forget.
    func enqueueSync(_ reason: SyncReason) async {
        if isSyncing {
            queue(reason)
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        var next: SyncReason? = reason
        while let current = next {
            await executeSync(current)
            next = dequeue()
        }
    }

    /// Holds `reason` until the sync in flight is done. Reasons coalesce
    /// into the highest-priority one, whose work covers theirs — except an
    /// audio event: no other sync fetches the song at the audio's moment,
    /// so it waits apart and is never dropped.
    private func queue(_ reason: SyncReason) {
        if reason == .audioMetadataChanged {
            isAudioEventPending = true
        } else if pendingReason.map({ reason.rawValue < $0.rawValue }) ?? true {
            pendingReason = reason
        }
        logSync("queue: \(reason) (pending after current sync)")
    }

    /// The next sync to run. A pending audio event goes first: it brings
    /// the song in the listener's ears, in one small request.
    private func dequeue() -> SyncReason? {
        if isAudioEventPending {
            isAudioEventPending = false
            return .audioMetadataChanged
        }
        let reason = pendingReason
        pendingReason = nil
        return reason
    }

    /// Begin (or resume) the 60s safety-net loop, every 15 s while a
    /// direct stream plays. Idempotent.
    func startPeriodicLoop() {
        guard periodicTask == nil else { return }
        logSync("Resuming periodic sync (every \(Int(Self.periodicInterval))s)")
        periodicTask = Task { [weak self] in
            // Wakes at the direct stream's cadence, so a fallback to MP3
            // is followed within 15 s rather than after the minute.
            var wakes = 0
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.directStreamInterval),
                    tolerance: .seconds(1)
                )
                guard !Task.isCancelled, let self else { break }
                wakes += 1
                guard Self.isPeriodicSyncDue(
                    afterWakes: wakes,
                    playingDirectStream: self.isPlayingDirectStream
                ) else { continue }
                wakes = 0
                await self.enqueueSync(.periodic)
            }
        }
    }

    /// Whether the periodic loop syncs after `wakes` wakes of
    /// `directStreamInterval` since its last sync.
    static func isPeriodicSyncDue(
        afterWakes wakes: Int,
        playingDirectStream: Bool
    ) -> Bool {
        playingDirectStream
            || Double(wakes) * directStreamInterval >= periodicInterval
    }

    /// True while the current radio station plays a direct stream, heard
    /// live: its song changes reach the app only with the poll.
    var isPlayingDirectStream: Bool {
        currentStation?.kind == .radio
            && isPlayingProvider?() == true
            && followsHlsAudioProvider?() == false
    }

    func stopPeriodicLoop() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Sync engine internals

    /// Dispatches a single sync iteration by reason kind (full vs offset
    /// diff vs live diff). A periodic tick becomes a full refresh once the
    /// 10-min window has elapsed. An audio event never does: a full refresh
    /// asks about the live timeline only, so the song the audio just
    /// reached waited for the next change and the title stayed a song
    /// behind. The tick runs the refresh that is due within a minute.
    private func executeSync(_ reason: SyncReason) async {
        switch reason {
        case .startup, .appResumed, .stationPlayed, .seekOffsetChanged:
            await doFullRefresh(reason: reason, promoted: false)
        case .audioMetadataChanged:
            await doAudioDiff()
        case .periodic:
            if isFullRefreshDue {
                await doFullRefresh(reason: reason, promoted: true)
            } else {
                await doPeriodicDiff()
            }
        }
    }

    /// True once 10 minutes have passed since the last full refresh, or
    /// none has succeeded yet.
    private var isFullRefreshDue: Bool {
        lastFullRefresh.map {
            Date().timeIntervalSince($0) >= Self.fullRefreshInterval
        } ?? true
    }

    /// Full refresh: GraphQL stations + live metadata, merged in one shot.
    /// Resets the offset cursor — the next audio event will repopulate it.
    /// The catalog is saved for the next launch (`StationCatalogCache`).
    private func doFullRefresh(reason: SyncReason, promoted: Bool) async {
        logSync("full refresh: \(reason)\(promoted ? " (promoted: 10-min window)" : "")")
        isLoading = true
        defer { isLoading = false }
        do {
            let liveTs = roundedTimestamp()
            async let stationsResult = repository.fetchStations(timestamp: liveTs)
            async let liveMetaResult = repository.fetchMetadata(timestamp: liveTs)
            async let privateRefresh: Void = refreshPrivateStations(
                reason: reason
            )

            let fresh = try await stationsResult
            let live = (try? await liveMetaResult) ?? [:]
            await privateRefresh

            stations = mergeMetadata(
                into: withPrivate(fresh), live: live, offset: nil
            )
            lastFetchTimestamp = liveTs
            lastOffsetFetchTimestamp = 0
            lastFullRefresh = Date()
            loadError = nil
            apiAnswered()

            refreshCurrentStation()
            recordLiveSongs()
            recordShownSong()
            loadMissingSongHistory()
            firstCatalogShown()
            startPeriodicLoop()
            await catalogCache.save(fresh)
        } catch {
            loadError = Self.loadErrorMessage(for: error)
            Analytics.captureError(error, context: "full_refresh")
            // With stations on screen (the catalog the last launch saved)
            // the app stays usable, so it keeps trying in the background:
            // the catalog and the songs come back by themselves with the
            // API.
            if !stations.isEmpty {
                startPeriodicLoop()
            }
        }
    }

    /// What the error screen tells the listener when the catalog cannot
    /// load. The error's own text was English and technical ("HTTP 404
    /// from API", "The request timed out."); analytics still gets the
    /// error itself.
    static func loadErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError,
           offlineErrorCodes.contains(urlError.code) {
            return "Nu ai conexiune la internet. "
                + "Verifică rețeaua și încearcă din nou."
        }
        return "Serverul nu răspunde acum. "
            + "Încearcă din nou în câteva momente."
    }

    /// Failures that mean the device cannot reach the internet, as
    /// opposed to an API that fails or does not answer.
    private static let offlineErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed,
    ]

    /// Runs once, when the session's first catalog is on screen: the
    /// favorites of an old save take the order they were shown in, and
    /// the lists get their first ranking.
    private func firstCatalogShown() {
        guard !hasLoadedCatalog else { return }
        hasLoadedCatalog = true
        keepShownFavoriteOrder()
        refreshListOrders()
    }

    /// Audio-event diff: fetch metadata at the audio's timestamp so the
    /// playing station's now_playing matches what the user actually hears.
    /// Single request — no live fetch.
    ///
    /// No settle delay before it: the triggers come when the audio reaches
    /// a song change (18–30 s after it happened live, long after the
    /// backend ingested it) or seconds after a tune-in, never at the live
    /// moment of a change.
    private func doAudioDiff() async {
        guard !stations.isEmpty else { return }
        lastAudioEventTime = Date()
        let askedFor = currentStation?.id

        // Without the audio's PROGRAM-DATE-TIME (a direct/MP3 stream, or
        // HLS before its playlist is parsed) the fetch is at wall clock,
        // so its answer is a live payload, not an audio-aligned one.
        let hlsTs = hlsPlaybackTimestampProvider?()
        let audioTs = hlsTs ?? roundedTimestamp()

        // A direct stream asks for the whole live timeline: heard live
        // from its start, it shows the station's live song even when that
        // has not changed since the last fetch, which a diff leaves out.
        // A diff from a fetch made while it was paused kept the song heard
        // before the pause on screen after the resume.
        let canDiff = hlsTs != nil &&
            lastOffsetFetchTimestamp > 0 &&
            audioTs > lastOffsetFetchTimestamp &&
            (audioTs - lastOffsetFetchTimestamp) <= Self.maxOffsetDiffGapSeconds
        let changesFrom: Int? = canDiff ? lastOffsetFetchTimestamp : nil

        let result: [Int: StationMetadata]
        do {
            result = try await repository.fetchMetadata(
                timestamp: audioTs,
                changesFromTimestamp: changesFrom
            )
        } catch {
            // The song the audio just reached is still unknown (the API out
            // of reach at the change): the safety net of the next periodic
            // tick asks for the audio's moment again. A direct stream that
            // just started is heard live: the next tick fetches the whole
            // live timeline, as its diff leaves out a station whose live
            // song has not changed since the last one.
            lastAudioEventTime = nil
            if hlsTs == nil { lastFetchTimestamp = 0 }
            if currentStation?.id == askedFor { settleAwaitedSong() }
            return
        }
        // Asked for the audio of the station current then: one tuned in
        // meanwhile is heard at another moment, and taking the answer as
        // its own showed a song from that other moment, then the right one.
        guard currentStation?.id == askedFor else { return }
        lastOffsetFetchTimestamp = audioTs
        apiAnswered()

        if !result.isEmpty {
            if hlsTs != nil {
                applyMerge(live: nil, offset: result)
            } else {
                applyMerge(live: result, offset: nil)
            }
        }
        settleAwaitedSong()
    }

    /// The engine retries or gave up before the current station's song
    /// came: Now Playing names the station until it comes. Following each
    /// retry round instead, the title went empty and back to the name at
    /// every attempt.
    func endAwaitingSong() {
        if isAwaitingSong { isAwaitingSong = false }
    }

    /// The API answered a sync: a history it left unanswered may be asked
    /// for again as its card takes focus.
    private func apiAnswered() {
        failedSongHistory.subtract(unansweredSongHistory)
    }

    /// Ends `isAwaitingSong` once the audio's own moment has been asked
    /// about, the API answering or not: a song not shown by then is not
    /// known, and the station's name takes the title.
    private func settleAwaitedSong() {
        guard isAwaitingSong, let station = currentStation else { return }
        if case .audio(_, let uncertainty) = songClock(for: station),
           uncertainty > 0 {
            return
        }
        isAwaitingSong = false
    }

    /// 60s safety-net diff: refreshes the visible station list at the live
    /// timeline. When audio events have gone quiet for [audioEventSafetyNet],
    /// also includes an offset fetch so the player UI doesn't sit stale.
    private func doPeriodicDiff() async {
        guard !stations.isEmpty else { return }

        let liveTs = roundedTimestamp()
        let hlsActive = isPlayingHlsProvider?() ?? false
        let audioStale = lastAudioEventTime.map {
            Date().timeIntervalSince($0) > Self.audioEventSafetyNet
        } ?? true
        let wantOffsetSafetyNet = hlsActive && audioStale

        let offsetTs = wantOffsetSafetyNet
            ? hlsPlaybackTimestampProvider?() ?? liveTs
            : liveTs
        let fetchOffset = wantOffsetSafetyNet && offsetTs != liveTs

        let canDiffLive = lastFetchTimestamp > 0
        let canDiffOffset = fetchOffset &&
            lastOffsetFetchTimestamp > 0 &&
            offsetTs > lastOffsetFetchTimestamp &&
            (offsetTs - lastOffsetFetchTimestamp) <= Self.maxOffsetDiffGapSeconds

        do {
            async let liveResult = repository.fetchMetadata(
                timestamp: liveTs,
                changesFromTimestamp: canDiffLive ? lastFetchTimestamp : nil
            )
            async let offsetResult: [Int: StationMetadata]? = {
                guard fetchOffset else { return nil }
                return try? await repository.fetchMetadata(
                    timestamp: offsetTs,
                    changesFromTimestamp: canDiffOffset ? lastOffsetFetchTimestamp : nil
                )
            }()
            // Private stations aren't in /stations-metadata — their
            // now_playing/uptime/listeners ride on the private payload,
            // so the 60s tick doubles as their metadata refresh (skipped
            // for the session once the device is known to have none).
            async let privateRefresh: Void = refreshPrivateStations(
                reason: .periodic
            )

            let live = try await liveResult
            let offset = await offsetResult
            await privateRefresh

            lastFetchTimestamp = liveTs
            apiAnswered()
            // Only an answer moves the offset cursor: the next diff from a
            // moment the API never answered for would leave out what
            // changed before it.
            if fetchOffset, offset != nil { lastOffsetFetchTimestamp = offsetTs }

            applyMerge(live: live, offset: offset)
            loadMissingSongHistory()
        } catch {
            Analytics.captureError(error, context: "periodic_sync")
        }
    }

    /// The playing station's song history, when the fetch at its tune-in
    /// went unanswered (the API out of reach): asked for again with each
    /// sync the API answers, so "Melodii recente" fills in by itself.
    private func loadMissingSongHistory() {
        guard let slug = currentStation?.slug,
              unansweredSongHistory.contains(slug)
        else { return }
        Task { [weak self] in
            await self?.loadSongHistoryIfNeeded(for: slug)
        }
    }

    /// Merges fetched metadata into the in-memory station list. Either
    /// map may be nil when only one source was fetched. Per station, the
    /// `SongClock` decides which payload may set the song; the station
    /// list is published only if a user-visible field actually changed.
    ///
    /// The catalog is first rebuilt against the current private-station
    /// cache: `/stations-metadata` never covers private stations, so
    /// their fresh `now_playing`/`uptime`/listeners arrive on the private
    /// payload itself. Runs even when both metadata maps are empty —
    /// a private-only change must still land.
    private func applyMerge(live: [Int: StationMetadata]?, offset: [Int: StationMetadata]?) {
        let oldPrivateIds = privateStationIds
        let publicPart = stations.filter { !oldPrivateIds.contains($0.id) }
        let base = withPrivate(publicPart)

        let merged = mergeMetadata(into: base, live: live ?? [:], offset: offset)
        if hasMeaningfulChanges(old: stations, new: merged) {
            stations = merged
            refreshCurrentStation()
            recordLiveSongs()
        }
        recordShownSong()
    }

    /// Adds every other station's live song to its history as it comes,
    /// so a tune-in to it knows at once the song its audio, minutes behind
    /// live, is in. Without that the station showed its name, then the
    /// song once its history came, and the song block changed twice.
    private func recordLiveSongs() {
        for station in stations where station.id != currentStation?.id {
            guard let nowPlaying = station.nowPlaying,
                  recordedLiveSongs[station.id] != nowPlaying,
                  let startedAt = station.songStartDate
            else { continue }
            recordedLiveSongs[station.id] = nowPlaying
            songHistory.record(
                songTitle: station.songTitle,
                artist: station.songArtist,
                songId: nowPlaying.song?.id ?? 0,
                startedAt: startedAt,
                thumbnailUrl: station.songThumbnailUrl,
                for: station.slug
            )
        }
    }

    /// Re-reads `currentStation` from the freshly merged list so Now
    /// Playing and the system's Now Playing show its new values.
    private func refreshCurrentStation() {
        guard let current = currentStation,
              let updated = stations.first(where: { $0.id == current.id })
        else { return }
        currentStation = updated
        if updated.nowPlaying != nil { isAwaitingSong = false }
    }

    /// Adds the song the playing station shows to its history — never a
    /// song from a payload the merge did not show. While its song follows
    /// its HLS audio, later plays stay hidden until the audio gets there,
    /// also while no song is known to be heard yet.
    private func recordShownSong() {
        guard let station = currentStation else { return }
        songHistory.record(
            songTitle: station.songTitle,
            artist: station.songArtist,
            songId: station.nowPlaying?.song?.id ?? 0,
            startedAt: station.songStartDate,
            thumbnailUrl: station.songThumbnailUrl,
            heardAt: songClock(for: station).heardAt,
            for: station.slug
        )
    }

    private func logSync(_ message: String) {
        #if DEBUG
        print("AppState: \(message)")
        #endif
    }

    /// Single entry point for the private-stations fetch policy:
    ///
    /// * Launch (`.startup`) and `.appResumed` always fetch — they also
    ///   re-arm polling that a confirmed-empty answer disabled.
    /// * Other reasons (periodic 60s tick, promoted refreshes) fetch only
    ///   while polling is enabled.
    /// * Confirmed EMPTY → remember, disable polling for the session,
    ///   clear the persisted copy (the device was de-allowlisted).
    /// * Non-empty → cache in memory + UserDefaults (instant next-launch
    ///   render) and keep the 60s cadence — this payload is the private
    ///   stations' only metadata source.
    /// * 404 (endpoint not deployed yet) → keep the last known list but
    ///   stop polling this session so we don't hammer a dead endpoint.
    /// * Any other failure → keep the last known list, keep the cache,
    ///   keep polling; the next cycle retries.
    private func refreshPrivateStations(reason: SyncReason) async {
        let isLaunchOrResume = reason == .startup || reason == .appResumed
        guard isLaunchOrResume || !privateFetchDisabled else { return }
        do {
            let fetched = try await repository.fetchPrivateStations(
                deviceId: DeviceIdentity.deviceId
            )
            privateStations = fetched
            privateFetchDisabled = fetched.isEmpty
            if fetched.isEmpty {
                defaults.removeObject(forKey: Keys.privateStations)
            } else if let data = try? JSONEncoder().encode(fetched) {
                defaults.set(data, forKey: Keys.privateStations)
            }
        } catch APIError.http(404) {
            logSync("private stations: endpoint 404 — polling off this session")
            privateFetchDisabled = true
        } catch {
            logSync("private stations: fetch failed (kept last known list)")
        }
    }

    /// Appends the cached private stations to a public catalog, deduped
    /// by id — a station present in both is public and the public entry
    /// wins (its metadata flows through `/stations-metadata` normally).
    /// Recomputes `privateStationIds` as a side effect so the pinned
    /// ordering always matches the catalog it was derived from.
    private func withPrivate(_ publicStations: [Station]) -> [Station] {
        let publicIds = Set(publicStations.map(\.id))
        let exclusives = privateStations.filter { !publicIds.contains($0.id) }
        privateStationIds = Set(exclusives.map(\.id))
        return publicStations + exclusives
    }

    /// Merges each station with its payloads under its `SongClock`:
    /// the playing HLS station's song follows its audio, every other
    /// station follows the live timeline, and listeners and uptime always
    /// come from the live payload when there is one.
    private func mergeMetadata(
        into source: [Station],
        live: [Int: StationMetadata],
        offset: [Int: StationMetadata]?
    ) -> [Station] {
        source.map { station in
            merged(
                station,
                live: live[station.id],
                offset: offset?[station.id],
                clock: songClock(for: station)
            )
        }
    }

    /// `station` merged with its payloads under `clock`. Only the audio
    /// clock needs the song on screen and the play the history knows the
    /// audio to be in: a full refresh rebuilds from the catalog, whose song
    /// is the live one, which the audio may not have reached.
    private func merged(
        _ station: Station,
        live: StationMetadata?,
        offset: StationMetadata?,
        clock: SongClock
    ) -> Station {
        var shown: NowPlaying?
        var heardPlay: NowPlaying?
        if case .audio(let heardAt, let uncertainty) = clock {
            shown = stations.first { $0.id == station.id }?.nowPlaying
            heardPlay = songHistory.play(
                heardAt: heardAt,
                uncertainty: uncertainty,
                for: station.slug
            )
            .map(NowPlaying.init(play:))
        }
        return StationMetadataMerge.merged(
            station,
            shown: shown,
            live: live,
            offset: offset,
            history: heardPlay,
            clock: clock
        )
        .withoutStaleSong
    }

    /// Which timeline may set this station's song: the audio's for the
    /// station whose radio HLS stream plays — connecting, paused and
    /// waiting to try again included — the live one for the rest. The
    /// audio is where the engine last heard it, or until it knows,
    /// `assumedHlsLag` behind live.
    ///
    /// A paused direct stream stopped where it was paused, heard live:
    /// following the live timeline, the next poll put a song the listener
    /// never heard on screen and in the system's Now Playing, as HLS did
    /// before. It plays live again from a resume.
    private func songClock(for station: Station) -> SongClock {
        guard station.id == currentStation?.id else { return .live }
        guard followsHlsAudioProvider?() ?? startsOnHls(station) else {
            return directStreamPausedAtProvider?()
                .map { .audio(heardAt: $0) } ?? .live
        }
        return hlsHeardDateProvider?().map { .audio(heardAt: $0) }
            ?? assumedAudioClock
    }

    /// The clock of `station` as the listener tunes in to it, before the
    /// engine plays it: a radio station that starts on HLS follows its
    /// audio, assumed `assumedHlsLag` behind live.
    private func tuneInClock(for station: Station) -> SongClock {
        startsOnHls(station) ? assumedAudioClock : .live
    }

    /// Whether `station` starts on radio HLS, which the engine plays
    /// behind live.
    private func startsOnHls(_ station: Station) -> Bool {
        station.kind == .radio && station.primaryStreamIsHls
    }

    /// How far behind live HLS audio is assumed to be until its playhead
    /// is known: where its playlist starts playback before the playlist's
    /// end — 18 s live, `seekMode`'s offset in the start variants, whose
    /// `EXT-X-START` is -120 and -300 — plus the up to 15 s that end trails
    /// real time. Measured on the tvOS 27 simulator (2026-10-31): 19–27 s
    /// live, 116–133 s and 302–303 s in the 2 and 5 minute modes. Taking
    /// the far end means a live song is never shown before the listener can
    /// have reached it.
    private var assumedHlsLag: TimeInterval {
        max(seekMode.offset, Self.liveStartBeforeEnd) + Self.playlistEndDelay
    }

    /// Where HLS audio is assumed to be until its playhead is known:
    /// `assumedHlsLag` behind live, or up to `assumedHlsLagSpread` later.
    private var assumedAudioClock: SongClock {
        .audio(
            heardAt: Date().addingTimeInterval(-assumedHlsLag),
            uncertainty: Self.assumedHlsLagSpread
        )
    }

    /// Where the listener of the current station is on the broadcast
    /// timeline: where its song clock puts the audio, live when it follows
    /// the live timeline. "Melodii recente" counts back from that moment,
    /// so its times agree with the song shown, connecting and paused
    /// included. Before the playhead is known, from the middle of where
    /// the audio can be: counted from the far end, the times often turned
    /// a minute when the measured lag replaced it, just as the rows faded
    /// in.
    ///
    /// Paused at a known moment, the clock stops there, and stays stopped
    /// while a resume or a retry connects, until audio is heard again: as
    /// a lag behind live it grew with every second, and the times,
    /// recounted every 10 s from a lag read at the last redraw, climbed a
    /// minute and fell back with each poll.
    var heardClock: HeardClock {
        guard let station = currentStation,
              case .audio(let heardAt, let uncertainty) = songClock(for: station)
        else { return .behindLive(0) }
        if uncertainty == 0,
           isPlaybackPaused || audioStoppedAtProvider?() != nil {
            return .stopped(at: heardAt)
        }
        return .behindLive(Date().timeIntervalSince(heardAt) - uncertainty / 2)
    }

    /// Cheap diff that catches the fields the UI actually shows. Avoids
    /// re-publishing `stations` (and re-rendering every grid cell) when
    /// only ignored fields like `uptime.timestamp` changed.
    private func hasMeaningfulChanges(old: [Station], new: [Station]) -> Bool {
        guard old.count == new.count else { return true }
        for (o, n) in zip(old, new) {
            if o.id != n.id ||
                o.songTitle != n.songTitle ||
                o.songArtist != n.songArtist ||
                // The like buttons name the song by its id, which an
                // aligned payload can bring for a song shown from the
                // history.
                o.nowPlaying?.song?.id != n.nowPlaying?.song?.id ||
                o.totalListeners != n.totalListeners ||
                o.isUp != n.isUp ||
                // Private stations refresh wholesale from the private
                // payload — playlist edits must reach the UI too.
                o.playlistItems != n.playlistItems {
                return true
            }
        }
        return false
    }

    // MARK: - Selection / playback

    /// Pick a station to play. The audio player observes `currentStation`
    /// and switches sources accordingly. Triggers a full refresh so the
    /// playing station's now-playing is fresh before audio starts.
    ///
    /// - Parameter browsingOrder: ids of the grid the station was opened
    ///   from, as shown; previous / next walk it. Nil when stepping
    ///   (Now Playing, remote commands) keeps the current one.
    func selectStation(_ station: Station, browsingOrder: [Int]? = nil) {
        let previous = currentStation
        if let browsingOrder {
            self.browsingOrder = browsingOrder
        }
        // The grid shows the live song, which a station heard behind live
        // is still minutes from: the station starts with a song its audio
        // can have reached, on screen and in the system's Now Playing, and
        // its history hides the plays ahead of the audio from the start.
        // The station already playing keeps its value, which every merge
        // keeps fresh: until the first one, the grid's copy still carries
        // the live song.
        if station.id != previous?.id {
            let tunedIn = merged(
                station, live: nil, offset: nil,
                clock: tuneInClock(for: station)
            )
            currentStation = tunedIn
            isAwaitingSong = startsOnHls(station)
                && station.nowPlaying?.song != nil
                && tunedIn.nowPlaying == nil
            // The list holds the station as Now Playing shows it, as every
            // merge leaves it: a merge whose song the grid's copy already
            // had changed nothing, and Now Playing kept no song, then the
            // station's name, when the refresh at the tune-in failed.
            if let index = stations.firstIndex(where: { $0.id == station.id }),
               stations[index].nowPlaying != tunedIn.nowPlaying {
                stations[index] = tunedIn
            }
        }
        recordShownSong()
        recordRecent(slug: station.slug)
        incrementPlayCount(slug: station.slug)

        // Eagerly seed song history for this station so the
        // "Melodii recente" list in NowPlayingView is already
        // populated by the time the user lands on it. No-op while
        // the API's history of the station is current (an open in
        // the last 10 minutes). Then those of the stations before
        // and after it, the likeliest next tune-ins: with theirs in,
        // previous / next show the song at once, not the station's
        // name until it comes.
        Task { [weak self] in
            await self?.loadSongHistoryIfNeeded(for: station.slug)
            await self?.loadNeighbourHistories(of: station)
        }

        // Tell the sync engine the user just picked a station.
        Task { [weak self] in
            await self?.enqueueSync(.stationPlayed)
        }

        reportListening(previous, station)
    }

    /// PostHog: stops the previous listening session (if any) and starts
    /// a new one, so dashboards can compute listen-duration distributions.
    static func reportToAnalytics(from previous: Station?, to station: Station) {
        if let previous, previous.id != station.id {
            Analytics.listeningStopped(
                stationSlug: previous.slug,
                stationTitle: previous.title,
                stationId: previous.id,
                durationSeconds: 0,            // tvOS doesn't track yet
                reason: "station_switch"
            )
        }
        Analytics.listeningStarted(
            stationSlug: station.slug,
            stationTitle: station.title,
            stationId: station.id,
            stationType: station.kindAnalyticsValue
        )
    }

    /// Called by `RootView` when the scene becomes `.active` after being
    /// in the background. Coming back is a natural boundary, so the lists
    /// are ranked again first, with the data at hand — reordering a second
    /// later, when the refresh lands, would move cards under the listener
    /// — then a full refresh picks up what changed while the app was away.
    func onAppResumed() async {
        refreshListOrders()
        await enqueueSync(.appResumed)
    }

    /// Fetches `/stations-metadata-history` for the given slug and seeds
    /// `songHistory`. Skipped while the station's history is current
    /// (`SongHistoryStore.hasCurrentHistory`), so re-entry to it is
    /// instant. A fetch the API did not answer is tried again with each
    /// sync while the station plays; one it answered without a history,
    /// at the next tune-in.
    func loadSongHistoryIfNeeded(for slug: String) async {
        guard !slug.isEmpty,
              !songHistory.hasCurrentHistory(for: slug),
              songHistoryRequests.insert(slug).inserted
        else { return }
        defer { songHistoryRequests.remove(slug) }
        let history: [SongHistoryItem]
        do {
            history = try await repository.fetchSongHistory(stationSlug: slug)
        } catch {
            failedSongHistory.insert(slug)
            if Self.isAnsweredWithoutHistory(error) {
                unansweredSongHistory.remove(slug)
            } else {
                unansweredSongHistory.insert(slug)
            }
            return
        }
        failedSongHistory.remove(slug)
        unansweredSongHistory.remove(slug)
        let entries: [SongEntry] = history.compactMap { item in
            guard let song = item.song else { return nil }
            return SongEntry(
                title: song.name,
                artist: song.artist?.name ?? "",
                songId: song.id,
                timestamp: item.date,
                thumbnailUrl: song.thumbnailUrl ?? song.artist?.thumbnailUrl
            )
        }
        songHistory.seed(entries, for: slug)
        // The plays can tell the song an HLS listener hears before the
        // audio-aligned payload does (`StationMetadataMerge.audibleSong`).
        if slug == currentStation?.slug {
            applyMerge(live: nil, offset: nil)
        }
    }

    /// A station's card took focus. When a tune-in to the station now
    /// would show its name, its song history loads, so the tune-in shows
    /// the song at once: heard minutes behind live, the station starts in
    /// the song before a live one that began within those minutes, which
    /// soon after launch only the history knows. The first tune-in after
    /// launch showed the station's name, then that song a moment later.
    func stationCardFocused(_ station: Station) {
        guard station.id != currentStation?.id,
              station.nowPlaying?.song != nil,
              // The API keeps no history of a private station.
              !privateStationIds.contains(station.id),
              !failedSongHistory.contains(station.slug),
              merged(
                  station, live: nil, offset: nil,
                  clock: tuneInClock(for: station)
              ).nowPlaying == nil
        else { return }
        Task { [weak self] in
            await self?.loadSongHistoryIfNeeded(for: station.slug)
        }
    }

    /// Loads the song histories of the stations after and before
    /// `station` in the grid it was opened from. Radio only: TV and
    /// playlist stations show no songs.
    ///
    /// Each once: in a grid of two both are the other station. Not one
    /// whose history just failed, which a tune-in asks for again.
    private func loadNeighbourHistories(of station: Station) async {
        let neighbours = [
            nextStation(after: station),
            previousStation(before: station),
        ]
        var slugs: [String] = []
        for neighbour in neighbours.compactMap({ $0 })
        where neighbour.kind == .radio && neighbour.id != station.id
            && !failedSongHistory.contains(neighbour.slug)
            && !slugs.contains(neighbour.slug) {
            slugs.append(neighbour.slug)
        }
        for slug in slugs {
            await loadSongHistoryIfNeeded(for: slug)
        }
    }

    /// Whether a failed history fetch was the API's answer: no history for
    /// the station (one the endpoint does not know, a private one, comes
    /// back as an error that does not decode as a history) or a refusal.
    /// No connection, a timeout or a server fault went unanswered.
    private static func isAnsweredWithoutHistory(_ error: Error) -> Bool {
        switch error {
        case APIError.decoding:
            return true
        case APIError.http(let status):
            return (400..<500).contains(status)
        default:
            return false
        }
    }

    /// Stations sorted using the user's saved preference. Private
    /// stations pin to the very top in every sort mode; favorites bubble
    /// to the top of the recommended list (matches the Flutter behavior).
    var sortedStations: [Station] {
        StationSortService.sort(
            stations,
            by: sortOption,
            playCounts: playCounts,
            favoriteSlugs: favorites.members,
            privateIds: privateStationIds
        )
    }

    /// The station after `station` in the grid it was opened from,
    /// wrapping around at the end. Used by "Postul următor" in Now
    /// Playing and by the remote's next-track command.
    func nextStation(after station: Station) -> Station? {
        adjacentStation(to: station, step: 1)
    }

    /// The station before `station` in the grid it was opened from,
    /// wrapping around at the beginning.
    func previousStation(before station: Station) -> Station? {
        adjacentStation(to: station, step: -1)
    }

    /// Walks the browsing snapshot; a station outside it (e.g. reached
    /// some other way), or alone in it, walks the "Posturi" list as shown
    /// instead. Ids of stations that left the catalog are skipped.
    private func adjacentStation(to station: Station, step: Int) -> Station? {
        let byId = Dictionary(
            stations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let id = StationOrder.neighbor(
            of: station.id,
            step: step,
            in: browsingOrder.filter { byId[$0] != nil },
            orElseIn: displayedStations(in: .all).map(\.id)
        ) else { return nil }
        return byId[id]
    }

    // MARK: - On-screen order

    /// A list as the grid shows it: in its fixed order, with every
    /// station's current values (song, listeners, uptime).
    func displayedStations(in list: StationList) -> [Station] {
        guard let order = listOrders[list] else { return ranked(list) }
        return order.arrange(members(of: list))
    }

    /// Ranks one list again. Called at natural boundaries only: switching
    /// to its tab and changing the sort.
    func refreshOrder(of list: StationList) {
        guard hasLoadedCatalog else { return }
        let order = StationOrder(ranked(list))
        guard listOrders[list] != order else { return }
        listOrders[list] = order
    }

    /// Ranks every list again: the first catalog load and the app
    /// returning to the foreground.
    func refreshListOrders() {
        guard hasLoadedCatalog else { return }
        var orders: [StationList: StationOrder] = [:]
        for list in StationList.allCases {
            orders[list] = StationOrder(ranked(list))
        }
        guard orders != listOrders else { return }
        listOrders = orders
    }

    /// The list in its live ranking.
    private func ranked(_ list: StationList) -> [Station] {
        switch list {
        case .all: return sortedStations
        case .favorites: return favoriteStations
        case .recents: return recentStations
        }
    }

    /// The list's stations without ranking them — newcomers are appended
    /// in this order. Only "Posturi" has a costly ranking to skip.
    private func members(of list: StationList) -> [Station] {
        switch list {
        case .all: return stations
        case .favorites, .recents: return ranked(list)
        }
    }

    private func incrementPlayCount(slug: String) {
        playCounts[slug, default: 0] += 1
        defaults.set(playCounts, forKey: Keys.playCounts)
    }

    // MARK: - Favorites

    func isFavorite(_ station: Station) -> Bool {
        favorites.contains(station.slug)
    }

    /// Adds the station to the favorites, last, or removes it.
    func toggleFavorite(_ station: Station) {
        let willBeFavorite = favorites.toggle(station.slug)
        defaults.set(favorites.slugs, forKey: Keys.favorites)
        Analytics.favoriteToggled(
            stationSlug: station.slug,
            willBeFavorite: willBeFavorite
        )
    }

    /// In the listener's order (see `FavoriteList`).
    var favoriteStations: [Station] {
        favorites.stations(among: stations)
    }

    /// Saves from before the favorites kept their order hold them in no
    /// particular order, while "Favorite" showed them in catalog order.
    /// The first catalog shown arranges them that way, once, so they do
    /// not come back reshuffled.
    private func keepShownFavoriteOrder() {
        guard !defaults.bool(forKey: Keys.favoriteOrderKept) else { return }
        favorites = favorites.arranged(asShown: stations.map(\.slug))
        defaults.set(favorites.slugs, forKey: Keys.favorites)
        defaults.set(true, forKey: Keys.favoriteOrderKept)
    }

    // MARK: - Recents

    private func recordRecent(slug: String) {
        recentSlugs.removeAll { $0 == slug }
        recentSlugs.insert(slug, at: 0)
        if recentSlugs.count > 20 {
            recentSlugs.removeLast(recentSlugs.count - 20)
        }
        defaults.set(recentSlugs, forKey: Keys.recents)
    }

    var recentStations: [Station] {
        recentSlugs.compactMap { slug in
            stations.first { $0.slug == slug }
        }
    }

    private enum Keys {
        /// The favorite slugs, in the listener's order since
        /// `favoriteOrderKept` is set.
        static let favorites = "tv.favoriteSlugs"
        static let favoriteOrderKept = "tv.favoriteOrderKept"
        static let recents = "tv.recentSlugs"
        static let sort = "tv.sortOption"
        static let playCounts = "tv.playCounts"
        static let privateStations = "tv.privateStations"
        static let seekMode = "tv.seekMode"
    }
}

// MARK: - Metadata merge policy

/// Which payload may set the song a station shows.
///
/// `/stations-metadata` answers for one moment: the live timeline (wall
/// clock) or the moment the HLS audio is at (its PROGRAM-DATE-TIME,
/// ~18–30 s behind live). For that half minute after every song change
/// the two disagree; letting both set the playing station's song made
/// Now Playing flip between them and the history read A, B, A.
enum SongClock: Equatable {
    /// The song follows the live timeline: every station that is not
    /// playing, and a playing direct (MP3/AAC) stream, which is live.
    case live
    /// The playing HLS station: its song follows the audio, which is at
    /// `heardAt` on the broadcast timeline — the playhead's
    /// PROGRAM-DATE-TIME; paused, where it was paused; while the station
    /// connects again, as far behind live as it was last heard. Before
    /// that it is an estimate: the earliest the audio can be, which it may
    /// be up to `uncertainty` past. Also a paused direct stream, whose
    /// audio stopped where it was paused.
    case audio(heardAt: Date, uncertainty: TimeInterval = 0)

    /// Where the audio is on the audio clock (at the earliest, for an
    /// estimate); nil on the live one.
    var heardAt: Date? {
        guard case .audio(let heardAt, _) = self else { return nil }
        return heardAt
    }
}

/// Where the listener is on the broadcast timeline, which "Melodii
/// recente" counts its times back from (`AppState.heardClock`).
enum HeardClock: Equatable {
    /// Moving with the wall clock, this many seconds behind it.
    case behindLive(TimeInterval)
    /// Stopped at a moment: the station is paused there.
    case stopped(at: Date)

    /// The broadcast moment the listener is at when the wall clock reads
    /// `date`.
    func heardNow(at date: Date) -> Date {
        switch self {
        case .behindLive(let lag): return date.addingTimeInterval(-lag)
        case .stopped(let moment): return moment
        }
    }
}

/// Pure merge of one station with its metadata payloads.
enum StationMetadataMerge {
    /// - Parameters:
    ///   - station: the station to update. After a full refresh its song
    ///     is the catalog's, i.e. the live one.
    ///   - shown: the song on screen; only the `.audio` clock uses it.
    ///   - live: the station's entry in a live payload, if any.
    ///   - offset: its entry in an audio-aligned payload, if any. Ignored
    ///     on the `.live` clock: it describes the playing station's audio
    ///     moment, which lags every other station's live song.
    ///   - history: the play the song history knows the audio to be in
    ///     (`SongHistoryStore.play(heardAt:uncertainty:for:)`); only the
    ///     `.audio` clock uses it.
    static func merged(
        _ station: Station,
        shown: NowPlaying? = nil,
        live: StationMetadata?,
        offset: StationMetadata?,
        history: NowPlaying? = nil,
        clock: SongClock
    ) -> Station {
        switch clock {
        case .live:
            guard let live else { return station }
            return station.merging(live, liveListeners: live.listeners)
        case .audio(let heardAt, _):
            var copy = station
            copy.nowPlaying = audibleSong(
                shown: shown,
                catalog: station.nowPlaying,
                live: live?.now_playing,
                offset: offset?.now_playing,
                history: history,
                heardAt: heardAt
            )
            // Listeners and uptime describe now, not the audio's moment.
            copy.totalListeners = live?.listeners ?? station.totalListeners
            copy.uptime = live?.uptime ?? offset?.uptime ?? station.uptime
            return copy
        }
    }

    /// The song an HLS listener hears when the audio is at `heardAt`: the
    /// newest song known to have started by then.
    ///
    /// Every source can know it. The audio-aligned payload was asked for
    /// the audio's own moment, so its song is heard by definition; the
    /// live payload, the catalog, the screen and the song history count
    /// once the audio has reached their song's start. A song the audio has
    /// not reached is never taken, whoever brought it: the title would run
    /// ahead of the audio and flip back. Ignoring live payloads altogether
    /// instead left the title a song behind whenever no aligned fetch
    /// followed a change. The newest reached song wins, so an aligned
    /// payload rounded down to its 10 s timestamp, from just before a
    /// change, cannot take back a song the audio has reached; a tie goes to
    /// the fresher source.
    ///
    /// When no song is known to be reached — a tune-in before the history
    /// and the aligned payload arrive — none is shown rather than the live
    /// one minutes ahead of the audio; only a song whose start is unknown
    /// stays, as the best guess.
    static func audibleSong(
        shown: NowPlaying?,
        catalog: NowPlaying?,
        live: NowPlayingMetadata?,
        offset: NowPlayingMetadata?,
        history: NowPlaying? = nil,
        heardAt: Date
    ) -> NowPlaying? {
        let candidates: [AudibleCandidate] = [
            offset.map { AudibleCandidate($0, isAudioAligned: true) },
            live.map { AudibleCandidate($0, isAudioAligned: false) },
            catalog.map(AudibleCandidate.init),
            shown.map(AudibleCandidate.init),
            history.map(AudibleCandidate.init),
        ].compactMap { $0 }
        var best: (candidate: AudibleCandidate, start: Date)?
        for candidate in candidates {
            let start = candidate.start
            let isReached = candidate.isAudioAligned
                || start.map { $0 <= heardAt } == true
            guard isReached else { continue }
            let rank = start ?? .distantPast
            if let best, best.start >= rank { continue }
            best = (candidate, rank)
        }
        guard let winner = best?.candidate else {
            return [shown, catalog].lazy.compactMap { $0 }.first {
                AudibleCandidate($0).start == nil
            }
        }
        return NowPlaying(
            id: (shown ?? catalog)?.id ?? 0,
            timestamp: winner.timestamp,
            song: winner.song
        )
    }
}

private extension NowPlaying {
    /// A play of the song history as a station's song, with the song's id
    /// when the history has it: a like of it names the song. Without one,
    /// the review would rate the station instead.
    init(play: SongEntry) {
        self.init(
            id: 0,
            timestamp: SongTimestamp.string(from: play.timestamp),
            song: Song(
                id: play.songId,
                name: play.title,
                thumbnailUrl: play.thumbnailUrl,
                artist: play.artist.isEmpty
                    ? nil
                    : Artist(id: 0, name: play.artist, thumbnailUrl: nil)
            )
        )
    }
}

/// One source's idea of the playing station's song.
private struct AudibleCandidate {
    let timestamp: String?
    let song: Song?
    /// Asked for at the audio's own moment, so heard by definition.
    let isAudioAligned: Bool

    init(_ payload: NowPlayingMetadata, isAudioAligned: Bool) {
        timestamp = payload.timestamp
        song = payload.song
        self.isAudioAligned = isAudioAligned
    }

    init(_ nowPlaying: NowPlaying) {
        timestamp = nowPlaying.timestamp
        song = nowPlaying.song
        isAudioAligned = false
    }

    /// When the song started on the broadcast timeline.
    var start: Date? { timestamp.flatMap(SongTimestamp.date(from:)) }
}
