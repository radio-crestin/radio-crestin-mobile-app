import Foundation
import SwiftUI

/// Why a metadata sync was requested. Drives the choice between full
/// refresh, audio-aligned offset diff, and live-timeline diff. Listed in
/// priority order — when multiple reasons coalesce while a sync is in
/// flight, the lower raw value (= higher priority) wins. Mirrors the
/// Dart `SyncReason` enum in `station_data_service.dart`.
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
/// station list (loaded from the REST `/stations` endpoint), favorites
/// (persisted in UserDefaults), recents (also persisted), and the
/// current selection driving Now Playing.
///
/// Owns the **unified metadata sync engine**: a single `enqueueSync(reason)`
/// entry point coalesces every refresh trigger (startup, app-resume,
/// station-play, seek-offset, audio-metadata, periodic). A 60s wall-clock
/// tick keeps the visible station list fresh; HLS DATERANGE events drive
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

    // MARK: - Published state
    @Published private(set) var stations: [Station] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    @Published private(set) var favoriteSlugs: Set<String> = []
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

    // MARK: - On-screen order

    /// The order each list was last ranked in. A list without an entry
    /// (before the first catalog load) shows its live ranking.
    @Published private(set) var listOrders: [StationList: StationOrder] = [:]

    /// Station ids of the grid the current station was opened from, in
    /// the order it showed. "Postul anterior / următor" and the remote's
    /// previous / next track walk it, so stepping never chases a list
    /// that re-ranks itself after each play.
    private var browsingOrder: [Int] = []

    /// Set by the first successful catalog load of the session — the
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

    /// Returns the PROGRAM-DATE-TIME of the audio currently being heard,
    /// unrounded, or nil if not playing HLS / playlist not yet parsed.
    /// Decides which songs the listener has reached.
    var hlsPlaybackDateProvider: (() -> Date?)?

    /// True when the currently playing stream is HLS. Used as a fallback
    /// trigger to fetch an offset metadata payload even when the precise
    /// HLS timestamp isn't yet available.
    var isPlayingHlsProvider: (() -> Bool)?

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

    /// Live-timeline cursor (Unix seconds, 10s-rounded). Sent as
    /// `changes_from_timestamp` on the next live diff.
    private var lastFetchTimestamp: Int = 0

    /// Offset-timeline cursor — stores the timestamp value sent on the
    /// last offset request, not wall-clock now, so it matches the server's
    /// cache key. Reset to 0 whenever the offset frame of reference may
    /// have shifted (full refresh, error recovery, init).
    private var lastOffsetFetchTimestamp: Int = 0

    /// When the last full refresh happened. Promotes the next sync to
    /// full once 10 minutes have elapsed.
    private var lastFullRefresh: Date?

    /// Last time the audio layer reported a metadata change (DATERANGE,
    /// timed metadata). Used by the periodic safety net.
    private var lastAudioEventTime: Date?

    /// Fixed cadence for the periodic safety-net poll.
    private static let periodicInterval: TimeInterval = 60

    /// 10-min full-refresh window.
    private static let fullRefreshInterval: TimeInterval = 10 * 60

    /// If audio events have gone quiet this long, the next periodic tick
    /// adds an offset fetch as a safety net.
    private static let audioEventSafetyNet: TimeInterval = 5 * 60

    /// How far behind live the HLS audio is assumed to be until its
    /// playlist is parsed and its PROGRAM-DATE-TIME known, on top of the
    /// `seekMode` offset. The join is 18 s before the playlist's end, which
    /// trails real time by up to a 6 s segment and its publication: 18–30 s.
    /// Taking the far end means a live song is never shown before the
    /// listener can have reached it.
    private static let assumedHlsLag: TimeInterval = 30

    /// Maximum gap (seconds) between consecutive offset-fetch timestamps
    /// before the differential is dropped. Guards against stale cursors after
    /// long pauses, app backgrounding, or shifts between the synthetic offset
    /// and the precise PROGRAM-DATE-TIME source.
    private static let maxOffsetDiffGapSeconds: Int = 60

    init(
        repository: StationRepository = StationRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.defaults = defaults
        self.favoriteSlugs = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
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
        // allowlisted device sees them immediately, before any network.
        // The startup full refresh replaces them with the live answer.
        if let data = defaults.data(forKey: Keys.privateStations),
           let cached = try? JSONDecoder().decode([Station].self, from: data),
           !cached.isEmpty {
            self.privateStations = cached
            self.stations = withPrivate([])
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

    /// Forces an out-of-cycle audio-aligned metadata fetch. Used by the
    /// AudioPlayer's DATERANGE callback when the HLS playlist announces
    /// that a new song just started in the audio.
    func refreshMetadataNow() async {
        await enqueueSync(.audioMetadataChanged)
    }

    /// Single entry point for every refresh. Coalesces overlapping
    /// triggers and runs them in priority order so concurrent callers
    /// can fire and forget.
    func enqueueSync(_ reason: SyncReason) async {
        if isSyncing {
            // Coalesce into the pending slot if this reason is higher
            // priority (lower raw value) than what's already queued.
            if pendingReason == nil || reason.rawValue < (pendingReason?.rawValue ?? Int.max) {
                pendingReason = reason
                logSync("queue: \(reason) (pending after current sync)")
            }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        var current = reason
        while true {
            await executeSync(current)
            guard let next = pendingReason else { break }
            pendingReason = nil
            current = next
        }
    }

    /// Begin (or resume) the 60s safety-net loop. Idempotent.
    func startPeriodicLoop() {
        guard periodicTask == nil else { return }
        logSync("Resuming periodic sync (every \(Int(Self.periodicInterval))s)")
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.periodicInterval * 1_000_000_000)
                )
                guard !Task.isCancelled else { break }
                await self?.enqueueSync(.periodic)
            }
        }
    }

    func stopPeriodicLoop() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Sync engine internals

    /// Dispatches a single sync iteration. Promotes any reason to a full
    /// refresh when the 10-min window has elapsed; otherwise routes by
    /// reason kind (full vs offset diff vs live diff).
    private func executeSync(_ reason: SyncReason) async {
        let fullDue = lastFullRefresh.map {
            Date().timeIntervalSince($0) >= Self.fullRefreshInterval
        } ?? true

        let isFullReason: Bool
        switch reason {
        case .startup, .appResumed, .stationPlayed, .seekOffsetChanged:
            isFullReason = true
        case .audioMetadataChanged, .periodic:
            isFullReason = false
        }

        if isFullReason || fullDue {
            await doFullRefresh(reason: reason, promoted: !isFullReason)
            return
        }
        if reason == .audioMetadataChanged {
            await doAudioDiff()
            return
        }
        await doPeriodicDiff()
    }

    /// Full refresh: GraphQL stations + live metadata, merged in one shot.
    /// Resets the offset cursor — the next audio event will repopulate it.
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

            refreshCurrentStation()
            recordShownSong()
            if !hasLoadedCatalog {
                hasLoadedCatalog = true
                refreshListOrders()
            }
            startPeriodicLoop()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Analytics.captureError(error, context: "full_refresh")
        }
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

        // Without the audio's PROGRAM-DATE-TIME (a direct/MP3 stream, or
        // HLS before its playlist is parsed) the fetch is at wall clock,
        // so its answer is a live payload, not an audio-aligned one.
        let hlsTs = hlsPlaybackTimestampProvider?()
        let audioTs = hlsTs ?? roundedTimestamp()

        let canDiff = lastOffsetFetchTimestamp > 0 &&
            audioTs > lastOffsetFetchTimestamp &&
            (audioTs - lastOffsetFetchTimestamp) <= Self.maxOffsetDiffGapSeconds
        let changesFrom: Int? = canDiff ? lastOffsetFetchTimestamp : nil

        let result = (try? await repository.fetchMetadata(
            timestamp: audioTs,
            changesFromTimestamp: changesFrom
        )) ?? [:]
        lastOffsetFetchTimestamp = audioTs

        guard !result.isEmpty else { return }
        if hlsTs != nil {
            applyMerge(live: nil, offset: result)
        } else {
            applyMerge(live: result, offset: nil)
        }
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
            if fetchOffset { lastOffsetFetchTimestamp = offsetTs }

            applyMerge(live: live, offset: offset)
        } catch {
            Analytics.captureError(error, context: "periodic_sync")
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
        }
        recordShownSong()
    }

    /// Re-reads `currentStation` from the freshly merged list so Now
    /// Playing and the system's Now Playing show its new values.
    private func refreshCurrentStation() {
        guard let current = currentStation,
              let updated = stations.first(where: { $0.id == current.id })
        else { return }
        currentStation = updated
    }

    /// Adds the song the playing station shows to its history — never a
    /// song from a payload the merge did not show. While its song follows
    /// its HLS audio, later plays stay hidden until the audio gets there.
    private func recordShownSong() {
        guard let station = currentStation else { return }
        let followsAudio: Bool
        switch songClock(for: station) {
        case .live: followsAudio = false
        case .audio: followsAudio = true
        }
        songHistory.record(
            songTitle: station.songTitle,
            artist: station.songArtist,
            startedAt: station.songStartDate,
            thumbnailUrl: station.songThumbnailUrl,
            isAudioAligned: followsAudio,
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
            let clock = songClock(for: station)
            // Only the audio clock needs the song on screen: a full
            // refresh rebuilds from the catalog, whose song is the live
            // one, which the audio may not have reached.
            let shown: NowPlaying?
            switch clock {
            case .live:
                shown = nil
            case .audio:
                shown = stations.first { $0.id == station.id }?.nowPlaying
            }
            return StationMetadataMerge.merged(
                station,
                shown: shown,
                live: live[station.id],
                offset: offset?[station.id],
                clock: clock
            )
        }
    }

    /// Which timeline may set this station's song: the audio's for the
    /// station whose HLS stream is playing, the live one for the rest.
    private func songClock(for station: Station) -> SongClock {
        guard station.id == currentStation?.id,
              isPlayingHlsProvider?() ?? station.primaryStreamIsHls
        else { return .live }
        let heardAt = hlsPlaybackDateProvider?()
            ?? Date().addingTimeInterval(
                -(seekMode.offset + Self.assumedHlsLag)
            )
        return .audio(heardAt: heardAt)
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
        currentStation = station
        recordRecent(slug: station.slug)
        incrementPlayCount(slug: station.slug)

        // Eagerly seed song history for this station so the
        // "Melodii recente" list in NowPlayingView is already
        // populated by the time the user lands on it. No-op when
        // the store already has entries for this station from a
        // previous open in this session.
        Task { [weak self] in
            await self?.loadSongHistoryIfNeeded(for: station.slug)
        }

        // Tell the sync engine the user just picked a station.
        Task { [weak self] in
            await self?.enqueueSync(.stationPlayed)
        }

        // PostHog: stop the previous session (if any) and start a new one
        // so dashboards can compute listen-duration distributions.
        if let prev = previous, prev.id != station.id {
            Analytics.listeningStopped(
                stationSlug: prev.slug,
                stationTitle: prev.title,
                stationId: prev.id,
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
    /// `songHistory`. Skipped when the store already has data so re-entry
    /// to the same station is instant.
    func loadSongHistoryIfNeeded(for slug: String) async {
        guard !slug.isEmpty else { return }
        if songHistory.hasHistory(for: slug) { return }
        guard let history = try? await repository.fetchSongHistory(stationSlug: slug)
        else { return }
        let entries: [SongEntry] = history.compactMap { item in
            guard let song = item.song else { return nil }
            return SongEntry(
                title: song.name,
                artist: song.artist?.name ?? "",
                timestamp: item.date,
                thumbnailUrl: song.thumbnailUrl ?? song.artist?.thumbnailUrl
            )
        }
        songHistory.seed(entries, for: slug)
    }

    /// Stations sorted using the user's saved preference. Private
    /// stations pin to the very top in every sort mode; favorites bubble
    /// to the top of the recommended list (matches the Flutter behavior).
    var sortedStations: [Station] {
        StationSortService.sort(
            stations,
            by: sortOption,
            playCounts: playCounts,
            favoriteSlugs: favoriteSlugs,
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
        favoriteSlugs.contains(station.slug)
    }

    func toggleFavorite(_ station: Station) {
        let willBeFavorite: Bool
        if favoriteSlugs.contains(station.slug) {
            favoriteSlugs.remove(station.slug)
            willBeFavorite = false
        } else {
            favoriteSlugs.insert(station.slug)
            willBeFavorite = true
        }
        defaults.set(Array(favoriteSlugs), forKey: Keys.favorites)
        Analytics.favoriteToggled(
            stationSlug: station.slug,
            willBeFavorite: willBeFavorite
        )
    }

    var favoriteStations: [Station] {
        stations.filter { favoriteSlugs.contains($0.slug) }
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
        static let favorites = "tv.favoriteSlugs"
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
    /// PROGRAM-DATE-TIME, or an estimate until the playlist is parsed.
    case audio(heardAt: Date)
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
    static func merged(
        _ station: Station,
        shown: NowPlaying? = nil,
        live: StationMetadata?,
        offset: StationMetadata?,
        clock: SongClock
    ) -> Station {
        switch clock {
        case .live:
            guard let live else { return station }
            return station.merging(live, liveListeners: live.listeners)
        case .audio(let heardAt):
            var copy = station
            copy.nowPlaying = audibleSong(
                shown: shown,
                catalog: station.nowPlaying,
                live: live?.now_playing,
                offset: offset?.now_playing,
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
    /// live payload, the catalog and the screen count once the audio has
    /// reached their song's start. A song the audio has not reached is
    /// never taken, whoever brought it: the title would run ahead of the
    /// audio and flip back. Ignoring live payloads altogether instead left
    /// the title a song behind whenever no aligned fetch followed a
    /// change. The newest reached song wins, so an aligned payload rounded
    /// down to its 10 s timestamp, from just before a change, cannot take
    /// back a song the audio has reached; a tie goes to the fresher
    /// source. When no song is known to be reached, the one on screen
    /// stays: it is the best guess until an aligned payload arrives.
    static func audibleSong(
        shown: NowPlaying?,
        catalog: NowPlaying?,
        live: NowPlayingMetadata?,
        offset: NowPlayingMetadata?,
        heardAt: Date
    ) -> NowPlaying? {
        let candidates: [AudibleCandidate] = [
            offset.map { AudibleCandidate($0, isAudioAligned: true) },
            live.map { AudibleCandidate($0, isAudioAligned: false) },
            catalog.map(AudibleCandidate.init),
            shown.map(AudibleCandidate.init),
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
        guard let winner = best?.candidate else { return shown ?? catalog }
        return NowPlaying(
            id: (shown ?? catalog)?.id ?? 0,
            timestamp: winner.timestamp,
            song: winner.song
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
