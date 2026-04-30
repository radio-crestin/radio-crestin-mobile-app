import Foundation
import SwiftUI

/// App-wide state, scoped to the lifetime of the SwiftUI App. Holds the
/// station list (loaded from GraphQL), favorites (persisted in
/// UserDefaults), recents (also persisted), and the current selection
/// driving Now Playing.
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

    // MARK: - Loading

    func loadStations() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await repository.fetchStations()
            stations = fresh
            loadError = nil
            // If the user already had a current station, refresh its
            // metadata from the new list (slug is the stable identifier)
            // and append the song change to history if it changed.
            if let current = currentStation,
               let updated = fresh.first(where: { $0.slug == current.slug }) {
                currentStation = updated
            }
            // Always run history capture against the fresh list so the
            // currently-playing station picks up new songs without us
            // needing a separate metadata poller.
            if let cur = currentStation {
                songHistory.record(
                    songTitle: cur.songTitle,
                    artist: cur.songArtist,
                    for: cur.slug
                )
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Selection / playback

    /// Pick a station to play. The audio player observes `currentStation`
    /// and switches sources accordingly.
    func selectStation(_ station: Station) {
        currentStation = station
        recordRecent(slug: station.slug)
        incrementPlayCount(slug: station.slug)
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

    private func incrementPlayCount(slug: String) {
        playCounts[slug, default: 0] += 1
        defaults.set(playCounts, forKey: Keys.playCounts)
    }

    // MARK: - Favorites

    func isFavorite(_ station: Station) -> Bool {
        favoriteSlugs.contains(station.slug)
    }

    func toggleFavorite(_ station: Station) {
        if favoriteSlugs.contains(station.slug) {
            favoriteSlugs.remove(station.slug)
        } else {
            favoriteSlugs.insert(station.slug)
        }
        defaults.set(Array(favoriteSlugs), forKey: Keys.favorites)
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
