import Foundation

/// The listener's favorite stations, in the listener's order: the order
/// they were added in, oldest first. The phone, Android TV and Mac apps
/// list them so (`StationDataService.setStationIsFavorite` adds a new
/// favorite last). A set lost the order, so "Favorite" showed the
/// stations in catalog order.
struct FavoriteList: Equatable {
    /// Station slugs, the first added first. No duplicates.
    private(set) var slugs: [String]

    /// The same slugs, for lookups: every grid asks once per card.
    private(set) var members: Set<String>

    /// `slugs` as saved, duplicates dropped.
    init(_ slugs: [String] = []) {
        var members: Set<String> = []
        self.slugs = slugs.filter { members.insert($0).inserted }
        self.members = members
    }

    func contains(_ slug: String) -> Bool {
        members.contains(slug)
    }

    /// Adds `slug` last, or removes it when it is a favorite already.
    /// Returns whether it is a favorite afterwards.
    mutating func toggle(_ slug: String) -> Bool {
        if members.remove(slug) != nil {
            slugs.removeAll { $0 == slug }
            return false
        }
        members.insert(slug)
        slugs.append(slug)
        return true
    }

    /// The favorites among `stations`, in this list's order.
    func stations(among stations: [Station]) -> [Station] {
        let bySlug = Dictionary(
            stations.map { ($0.slug, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return slugs.compactMap { bySlug[$0] }
    }

    /// This list with the favorites `shown` lists put in its order, in
    /// the places they held; the others (a station the catalog no longer
    /// lists) keep theirs. Mirrors the phone's `setFavoriteOrder`. Gives
    /// a save from before the order was kept the order it was shown in.
    func arranged(asShown shown: [String]) -> FavoriteList {
        var movingSet: Set<String> = []
        let moving = shown.filter {
            members.contains($0) && movingSet.insert($0).inserted
        }
        var next = moving.makeIterator()
        return FavoriteList(slugs.map { slug in
            movingSet.contains(slug) ? next.next() ?? slug : slug
        })
    }
}
