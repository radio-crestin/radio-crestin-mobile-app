import Foundation
import SwiftUI

/// App-wide state, scoped to the lifetime of the SwiftUI App. Holds the
/// station list (loaded from the REST `/stations` endpoint), favorites
/// (persisted in UserDefaults), recents (also persisted), and the
/// current selection driving Now Playing.
///
/// Also owns the **metadata sync loop**: every 10 seconds it fetches
/// `/stations-metadata` and merges `now_playing` + `uptime` + listener
/// counts into the live station list. When the active stream is HLS
/// (which lags the broadcast by 6–30s) the request is parameterised
/// with the EXT-X-PROGRAM-DATE-TIME of the audio currently being heard,
/// so the song shown matches the song the user is hearing. Mirrors the
/// Flutter `StationDataService._pollMetadata` contract.
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

    // MARK: - Polling state

    private var pollTask: Task<Void, Never>?

    /// Unix timestamp (seconds, 10s-rounded) of the last successful
    /// metadata fetch — used as `changes_from_timestamp` on the next
    /// poll so the server only sends rows that actually changed.
    private var lastFetchTimestamp: Int = 0

    /// When the last full refresh happened. Triggers a heavy `/stations`
    /// re-fetch every 30 minutes so descriptions / streams stay current.
    private var lastFullRefresh: Date?

    private static let pollInterval: TimeInterval = 10
    private static let fullRefreshInterval: TimeInterval = 30 * 60

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
        pollTask?.cancel()
    }

    // MARK: - Loading

    /// Initial / forced full refresh — fetches the heavy `/stations`
    /// payload, merges live `now_playing` + `uptime`, then starts the
    /// 10s metadata poll if it isn't already running.
    func loadStations() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let liveTs = roundedTimestamp()
            // Parallel: full station list + live metadata. If HLS is
            // already playing (rare on first load, possible on re-entry)
            // we also fetch an offset metadata payload so the active
            // station's now_playing matches the audio.
            let hlsTs = hlsPlaybackTimestampProvider?()
            async let stationsResult = repository.fetchStations(timestamp: liveTs)
            async let liveMetaResult = repository.fetchMetadata(timestamp: liveTs)
            async let offsetMetaResult: [Int: StationMetadata]? = {
                guard let hlsTs else { return nil }
                return try? await repository.fetchMetadata(timestamp: hlsTs)
            }()

            let fresh = try await stationsResult
            let live = (try? await liveMetaResult) ?? [:]
            let offset = await offsetMetaResult

            stations = mergeMetadata(into: fresh, live: live, offset: offset)
            lastFetchTimestamp = liveTs
            lastFullRefresh = Date()
            loadError = nil

            // Refresh the user's selection from the new list.
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
            startPollingIfNeeded()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Analytics.captureError(error, context: "load_stations")
        }
    }

    // MARK: - Metadata polling

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.pollOnce()
            }
        }
    }

    /// Forces an out-of-cycle metadata poll. Used when something has just
    /// changed — the user picked a station, the HLS timeline finished
    /// establishing, app foregrounded — and we don't want to wait up to
    /// 10s for the next scheduled tick before the now-playing line on
    /// screen reflects the audio.
    func refreshMetadataNow() async {
        await pollOnce()
    }

    /// Single poll iteration. Promotes to a full refresh after 30
    /// minutes, otherwise issues a differential metadata fetch and
    /// merges the result into `stations`.
    private func pollOnce() async {
        guard !stations.isEmpty else { return }

        // Full refresh window? (every 30 min) — re-fetch everything.
        if let last = lastFullRefresh,
           Date().timeIntervalSince(last) >= Self.fullRefreshInterval {
            await loadStations()
            return
        }

        let liveTs = roundedTimestamp()
        let hlsTs = hlsPlaybackTimestampProvider?()
        let hlsActive = isPlayingHlsProvider?() ?? false
        let needsOffset = hlsTs != nil || hlsActive

        do {
            // Live (differential) covers every station + listener counts.
            // Offset is only needed when HLS is active so the playing
            // station's now_playing matches the audio being heard.
            async let liveResult = repository.fetchMetadata(
                timestamp: liveTs,
                changesFromTimestamp: lastFetchTimestamp
            )
            async let offsetResult: [Int: StationMetadata]? = {
                guard needsOffset else { return nil }
                return try? await repository.fetchMetadata(
                    timestamp: hlsTs ?? liveTs
                )
            }()

            let live = try await liveResult
            let offset = await offsetResult

            lastFetchTimestamp = liveTs

            if live.isEmpty && (offset?.isEmpty ?? true) {
                // Nothing changed — let the UI keep what it has.
                return
            }

            let merged = mergeMetadata(into: stations, live: live, offset: offset)
            // Only republish when something user-visible actually moved.
            if hasMeaningfulChanges(old: stations, new: merged) {
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
        } catch {
            // Polling failures are quiet by design — try again in 10s.
            Analytics.captureError(error, context: "poll_metadata")
        }
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
    /// and switches sources accordingly.
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
