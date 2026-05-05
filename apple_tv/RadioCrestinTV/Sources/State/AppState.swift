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
        didSet { defaults.set(sortOption.rawValue, forKey: Keys.sort) }
    }

    @Published var currentStation: Station?
    let songHistory = SongHistoryStore()

    // MARK: - Audio sync hooks (set by RootView after AudioPlayer init)

    /// Returns the 10s-aligned PROGRAM-DATE-TIME of the audio currently
    /// being heard, or nil if not playing HLS / playlist not yet parsed.
    var hlsPlaybackTimestampProvider: (() -> Int?)?

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

    /// Settle delay between detecting an audio metadata change locally
    /// (HLS DATERANGE / ICY tag) and querying the backend. Gives the
    /// `/stations-metadata` ingestion path a moment to pick up the new
    /// song before we ask for it.
    private static let audioEventSettleDelay: TimeInterval = 2

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
        if let raw = defaults.dictionary(forKey: Keys.playCounts) as? [String: Int] {
            self.playCounts = raw
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

            let fresh = try await stationsResult
            let live = (try? await liveMetaResult) ?? [:]

            stations = mergeMetadata(into: fresh, live: live, offset: nil)
            lastFetchTimestamp = liveTs
            lastOffsetFetchTimestamp = 0
            lastFullRefresh = Date()
            loadError = nil

            if let current = currentStation,
               let updated = stations.first(where: { $0.slug == current.slug }) {
                currentStation = updated
            }
            if let cur = currentStation {
                songHistory.record(
                    songTitle: cur.songTitle,
                    artist: cur.songArtist,
                    for: cur.slug
                )
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
    private func doAudioDiff() async {
        guard !stations.isEmpty else { return }
        lastAudioEventTime = Date()

        // Brief settle so the backend ingestion has caught up with the
        // song change the audio just announced.
        logSync("audio diff: settling \(Int(Self.audioEventSettleDelay))s before fetch")
        try? await Task.sleep(
            nanoseconds: UInt64(Self.audioEventSettleDelay * 1_000_000_000)
        )

        let hlsActive = isPlayingHlsProvider?() ?? false
        let hlsTs = hlsPlaybackTimestampProvider?()
        let audioTs: Int
        if let hlsTs {
            audioTs = hlsTs
        } else if hlsActive {
            audioTs = roundedTimestamp()
        } else {
            // Direct/MP3 stream — audio is "live", so use wall-clock.
            audioTs = roundedTimestamp()
        }

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
        applyMerge(live: nil, offset: result)
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

        var offsetTs = liveTs
        if wantOffsetSafetyNet {
            offsetTs = hlsPlaybackTimestampProvider?() ?? liveTs
        }
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

            let live = try await liveResult
            let offset = await offsetResult

            lastFetchTimestamp = liveTs
            if fetchOffset { lastOffsetFetchTimestamp = offsetTs }

            applyMerge(live: live, offset: offset)
        } catch {
            Analytics.captureError(error, context: "periodic_sync")
        }
    }

    /// Merges fetched metadata into the in-memory station list. Either
    /// map may be nil when only one source was fetched. Per-station,
    /// picks the HLS-aligned (offset) source for the playing station and
    /// the live source for everyone else, then publishes only if a
    /// user-visible field actually changed.
    private func applyMerge(live: [Int: StationMetadata]?, offset: [Int: StationMetadata]?) {
        if (live?.isEmpty ?? true) && (offset?.isEmpty ?? true) { return }

        let merged = mergeMetadata(into: stations, live: live ?? [:], offset: offset)
        guard hasMeaningfulChanges(old: stations, new: merged) else { return }
        stations = merged
        if let current = currentStation,
           let updated = stations.first(where: { $0.slug == current.slug }) {
            currentStation = updated
            songHistory.record(
                songTitle: updated.songTitle,
                artist: updated.songArtist,
                for: updated.slug
            )
        }
    }

    private func logSync(_ message: String) {
        #if DEBUG
        print("AppState: \(message)")
        #endif
    }

    /// Picks the right metadata source per station and merges it in.
    /// Mirrors `_mergeStationWithMetadata` in `station_data_service.dart`:
    /// HLS-playing stations get the offset payload (so the song matches
    /// the audio), every other station gets the live payload, and the
    /// listener count always comes from the live payload.
    private func mergeMetadata(
        into source: [Station],
        live: [Int: StationMetadata],
        offset: [Int: StationMetadata]?
    ) -> [Station] {
        source.map { station in
            let useOffset = shouldUseOffsetMetadata(station)
            let primary = useOffset ? offset : live
            let fallback = useOffset ? live : offset
            guard let metadata = primary?[station.id] ?? fallback?[station.id] else {
                return station
            }
            let liveListeners = live[station.id]?.listeners
            return station.merging(metadata, liveListeners: liveListeners)
        }
    }

    /// True when the offset (HLS-aligned) metadata should be preferred
    /// for this station. Currently only the actively-playing HLS stream
    /// qualifies; everything else uses the live timestamp.
    private func shouldUseOffsetMetadata(_ station: Station) -> Bool {
        guard let current = currentStation, current.id == station.id else {
            return false
        }
        return isPlayingHlsProvider?() ?? station.primaryStreamIsHls
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
                o.isUp != n.isUp {
                return true
            }
        }
        return false
    }

    // MARK: - Selection / playback

    /// Pick a station to play. The audio player observes `currentStation`
    /// and switches sources accordingly. Triggers a full refresh so the
    /// playing station's now-playing is fresh before audio starts.
    func selectStation(_ station: Station) {
        let previous = currentStation
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
            stationId: station.id
        )
    }

    /// Called when the SwiftUI scene phase becomes `.active` after a
    /// `.background` or `.inactive` transition — triggers a full refresh
    /// to pick up changes that happened while the app was away.
    func onAppResumed() async {
        await enqueueSync(.appResumed)
    }

    /// Fetches `/stations-metadata-history` for the given slug and seeds
    /// `songHistory`. Skipped when the store already has data so re-entry
    /// to the same station is instant.
    func loadSongHistoryIfNeeded(for slug: String) async {
        guard !slug.isEmpty else { return }
        if !songHistory.entries(for: slug).isEmpty { return }
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

    /// Stations sorted using the user's saved preference. Favorites bubble
    /// to the top of the recommended list (matches the Flutter behavior).
    var sortedStations: [Station] {
        StationSortService.sort(
            stations,
            by: sortOption,
            playCounts: playCounts,
            favoriteSlugs: favoriteSlugs
        )
    }

    /// Returns the next station in the current sort order, wrapping
    /// around at the end. Used by the prev/next controls in Now Playing.
    func nextStation(after station: Station) -> Station? {
        let list = sortedStations
        guard !list.isEmpty else { return nil }
        guard let idx = list.firstIndex(where: { $0.id == station.id }) else {
            return list.first
        }
        return list[(idx + 1) % list.count]
    }

    /// Returns the previous station in the current sort order, wrapping
    /// around at the beginning.
    func previousStation(before station: Station) -> Station? {
        let list = sortedStations
        guard !list.isEmpty else { return nil }
        guard let idx = list.firstIndex(where: { $0.id == station.id }) else {
            return list.last
        }
        return list[idx == 0 ? list.count - 1 : idx - 1]
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
    }
}
