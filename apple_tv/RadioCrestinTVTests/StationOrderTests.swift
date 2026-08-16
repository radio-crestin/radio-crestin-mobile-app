import XCTest
@testable import RadioCrestinTV

/// Guards the "one source of truth for the display order" contract:
/// the grid and the prev/next controls must walk the same array, that
/// array must not reshuffle under metadata churn, and a full cycle of
/// `next` must visit every station exactly once.
final class StationOrderTests: XCTestCase {

    private func station(
        id: Int,
        slug: String,
        listeners: Int = 0,
        rating: Double = 0,
        reviews: Int = 0
    ) -> Station {
        Station(
            id: id, slug: slug, title: slug, order: 0,
            thumbnailUrl: nil, totalListeners: listeners,
            stationStreams: [
                StationStream(order: 0, type: "HLS", streamUrl: "https://x/\(slug)")
            ],
            uptime: nil, nowPlaying: nil,
            reviewsStats: ReviewsStats(
                averageRating: rating, numberOfReviews: reviews
            ),
            stationType: nil, playlistItems: nil, hlsDvrStreamUrl: nil
        )
    }

    private var sample: [Station] {
        (1...7).map { station(id: $0, slug: "s\($0)", listeners: $0 * 10) }
    }

    // MARK: - Cycling covers the whole list, in display order

    func test_repeated_next_visits_every_station_once_per_cycle() {
        let order = sample
        var visited: [Int] = []
        var current = order[0]
        for _ in 0..<order.count {
            visited.append(current.id)
            guard let next = StationCycle.next(after: current.id, in: order)
            else { return XCTFail("next returned nil mid-cycle") }
            current = next
        }
        XCTAssertEqual(visited, order.map(\.id),
                       "next must follow the displayed order exactly")
        XCTAssertEqual(Set(visited).count, order.count,
                       "no station may be visited twice per cycle")
        XCTAssertEqual(current.id, order[0].id, "the cycle must wrap")
    }

    func test_repeated_previous_visits_every_station_once_per_cycle() {
        let order = sample
        var visited: [Int] = []
        var current = order[0]
        for _ in 0..<order.count {
            visited.append(current.id)
            guard let prev = StationCycle.previous(before: current.id, in: order)
            else { return XCTFail("previous returned nil mid-cycle") }
            current = prev
        }
        XCTAssertEqual(visited, [1, 7, 6, 5, 4, 3, 2])
        XCTAssertEqual(Set(visited).count, order.count)
        XCTAssertEqual(current.id, order[0].id)
    }

    func test_next_wraps_at_the_end_and_previous_at_the_start() {
        let order = sample
        XCTAssertEqual(StationCycle.next(after: 7, in: order)?.id, 1)
        XCTAssertEqual(StationCycle.previous(before: 1, in: order)?.id, 7)
    }

    func test_cycling_an_unknown_or_missing_id_falls_into_the_list() {
        let order = sample
        XCTAssertEqual(StationCycle.next(after: 999, in: order)?.id, 1)
        XCTAssertEqual(StationCycle.previous(before: 999, in: order)?.id, 7)
        XCTAssertEqual(StationCycle.next(after: nil, in: order)?.id, 1)
    }

    func test_cycling_an_empty_list_yields_nil() {
        XCTAssertNil(StationCycle.next(after: 1, in: []))
        XCTAssertNil(StationCycle.previous(before: 1, in: []))
    }

    // MARK: - Frozen order

    func test_order_is_stable_when_only_metadata_changes() {
        var freezer = StationOrderFreezer()
        let initial = sample
        var recomputes = 0
        let first = freezer.order(initial, sort: .recommended) {
            recomputes += 1
            return initial.reversed()
        }
        XCTAssertEqual(recomputes, 1)
        XCTAssertEqual(first.map(\.id), initial.reversed().map(\.id))

        // A metadata poll: same stations, wildly different listener counts.
        let churned = initial.map {
            station(id: $0.id, slug: $0.slug, listeners: 9_999 - $0.id)
        }
        let second = freezer.order(churned, sort: .recommended) {
            recomputes += 1
            return churned      // a different order, if it were consulted
        }
        XCTAssertEqual(recomputes, 1, "metadata churn must not resort")
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        // Fresh values still reach the UI, only the positions are pinned.
        XCTAssertEqual(second.first?.totalListeners, 9_999 - 7)
    }

    func test_order_recomputes_when_the_sort_option_changes() {
        var freezer = StationOrderFreezer()
        let list = sample
        _ = freezer.order(list, sort: .recommended) { list }
        var recomputed = false
        let result = freezer.order(list, sort: .alphabetical) {
            recomputed = true
            return list.reversed()
        }
        XCTAssertTrue(recomputed)
        XCTAssertEqual(result.map(\.id), list.reversed().map(\.id))
    }

    func test_order_recomputes_when_the_catalog_membership_changes() {
        var freezer = StationOrderFreezer()
        let list = sample
        _ = freezer.order(list, sort: .recommended) { list }
        let extended = list + [station(id: 8, slug: "s8")]
        var recomputed = false
        let result = freezer.order(extended, sort: .recommended) {
            recomputed = true
            return extended
        }
        XCTAssertTrue(recomputed)
        XCTAssertEqual(result.count, 8)
    }

    func test_frozen_order_contains_every_station_exactly_once() {
        var freezer = StationOrderFreezer()
        let list = sample
        let result = freezer.order(list, sort: .recommended) { list.shuffled() }
        XCTAssertEqual(Set(result.map(\.id)), Set(list.map(\.id)))
        XCTAssertEqual(result.count, list.count)
    }

    // MARK: - AppState wiring

    @MainActor
    func test_appstate_next_walks_the_same_array_the_grid_renders() {
        let defaults = UserDefaults(suiteName: "tv.order.tests")!
        defaults.removePersistentDomain(forName: "tv.order.tests")
        let state = AppState(defaults: defaults)
        state.replaceStationsForTesting(sample)

        let displayed = state.sortedStations
        XCTAssertEqual(displayed.count, 7)

        var visited: [Int] = []
        var current = displayed[0]
        for _ in 0..<displayed.count {
            visited.append(current.id)
            // Selecting bumps the play count — the exact signal that used
            // to reshuffle `.recommended` between two presses of "next".
            state.selectStation(current)
            guard let next = state.nextStation(after: current) else {
                return XCTFail("nextStation returned nil")
            }
            current = next
        }
        XCTAssertEqual(visited, displayed.map(\.id))
        XCTAssertEqual(state.sortedStations.map(\.id), displayed.map(\.id),
                       "playing stations must not reorder the list")
    }
}
