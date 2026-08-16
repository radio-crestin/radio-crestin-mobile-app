import Foundation

/// Keeps the station list in ONE stable display order and walks it.
///
/// Both types here exist because the grid and the prev/next controls must
/// agree exactly. Previously `sortedStations` re-ran the sort on every
/// read, and the `.recommended` strategy depends on per-user play counts
/// and on live listener counts — so selecting a station (which bumps its
/// play count) and every 60s metadata poll silently reshuffled the list.
/// Prev/next then walked an order the user had never seen: stations were
/// skipped, and the traversal did not match the rendered grid.

// MARK: - Frozen order

/// Computes the display order once and reuses it until the catalog
/// membership or the sort option actually changes.
///
/// Deliberately insensitive to metadata churn: listener counts, now-playing
/// songs, play counts, and favorites all change constantly, and none of
/// them may move a card the user is looking at.
struct StationOrderFreezer {
    /// Station ids in display order. Empty until the first `order` call.
    private(set) var frozenIds: [Int] = []

    /// What the frozen order was computed for. A change here — and only a
    /// change here — triggers a recompute.
    private var key: Key?

    private struct Key: Equatable {
        let sort: StationSort
        let ids: Set<Int>
    }

    /// Returns `stations` arranged in the frozen display order.
    ///
    /// `freshOrder` is only invoked when the order actually has to be
    /// recomputed, so callers can pass an expensive sort without paying
    /// for it on every metadata poll.
    mutating func order(
        _ stations: [Station],
        sort: StationSort,
        freshOrder: () -> [Station]
    ) -> [Station] {
        let newKey = Key(sort: sort, ids: Set(stations.map(\.id)))
        if newKey != key {
            key = newKey
            frozenIds = freshOrder().map(\.id)
        }
        let byId = Dictionary(
            stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // `frozenIds` is derived from exactly this id set, so every station
        // appears exactly once — no filtering can drop or duplicate one.
        return frozenIds.compactMap { byId[$0] }
    }
}

// MARK: - Cycling

/// Walks a display-ordered station list. Wraps at both ends, and — because
/// it indexes the very array the grid renders — a full cycle of `next`
/// visits every station exactly once.
enum StationCycle {
    static func next(after id: Int?, in order: [Station]) -> Station? {
        guard !order.isEmpty else { return nil }
        guard let id, let index = order.firstIndex(where: { $0.id == id })
        else { return order.first }
        return order[(index + 1) % order.count]
    }

    static func previous(before id: Int?, in order: [Station]) -> Station? {
        guard !order.isEmpty else { return nil }
        guard let id, let index = order.firstIndex(where: { $0.id == id })
        else { return order.last }
        return order[index == 0 ? order.count - 1 : index - 1]
    }
}
