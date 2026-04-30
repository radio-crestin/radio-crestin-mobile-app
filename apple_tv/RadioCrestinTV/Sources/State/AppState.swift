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

    @Published var currentStation: Station?

    init(
        repository: StationRepository = StationRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.defaults = defaults
        self.favoriteSlugs = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        self.recentSlugs = defaults.stringArray(forKey: Keys.recents) ?? []
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
            // metadata from the new list (slug is the stable identifier).
            if let current = currentStation,
               let updated = fresh.first(where: { $0.slug == current.slug }) {
                currentStation = updated
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
    }
}
