import XCTest
@testable import RadioCrestinTV

/// The fixed on-screen order of a station list: how it lays out fresh
/// station values, how previous / next walk it, and which card gets focus
/// back when Now Playing closes.
final class StationOrderTests: XCTestCase {

    private func station(_ id: Int, listeners: Int = 0) -> Station {
        Station(
            id: id,
            slug: "s\(id)",
            title: "S\(id)",
            order: 0,
            thumbnailUrl: nil,
            totalListeners: listeners,
            stationStreams: [],
            uptime: nil,
            nowPlaying: nil,
            reviewsStats: nil,
            stationType: nil,
            playlistItems: nil,
            hlsDvrStreamUrl: nil
        )
    }

    // MARK: - arrange(_:)

    func test_arrange_keeps_the_snapshot_order() {
        let order = StationOrder([station(3), station(1), station(2)])
        let arranged = order.arrange([station(1), station(2), station(3)])
        XCTAssertEqual(arranged.map(\.id), [3, 1, 2])
    }

    func test_arrange_takes_the_values_from_the_members() {
        let order = StationOrder(ids: [1, 2])
        let arranged = order.arrange([station(2), station(1, listeners: 99)])
        XCTAssertEqual(arranged.map(\.id), [1, 2])
        XCTAssertEqual(arranged.first?.totalListeners, 99)
    }

    func test_arrange_drops_stations_that_left_the_list() {
        let order = StationOrder(ids: [3, 1, 2])
        XCTAssertEqual(order.arrange([station(1), station(3)]).map(\.id), [3, 1])
    }

    func test_arrange_appends_new_stations_at_the_end_in_member_order() {
        let order = StationOrder(ids: [3, 1])
        let arranged = order.arrange([
            station(5), station(1), station(4), station(3),
        ])
        XCTAssertEqual(arranged.map(\.id), [3, 1, 5, 4])
    }

    func test_arrange_shows_a_repeated_id_once() {
        let order = StationOrder(ids: [1, 1, 2])
        let arranged = order.arrange([station(1), station(2), station(1)])
        XCTAssertEqual(arranged.map(\.id), [1, 2])
    }

    func test_an_empty_order_keeps_the_member_order() {
        let arranged = StationOrder(ids: []).arrange([station(2), station(1)])
        XCTAssertEqual(arranged.map(\.id), [2, 1])
    }

    // MARK: - neighbor(of:step:in:)

    func test_neighbor_steps_forward_and_back() {
        let ids = [10, 20, 30]
        XCTAssertEqual(StationOrder.neighbor(of: 10, step: 1, in: ids), 20)
        XCTAssertEqual(StationOrder.neighbor(of: 20, step: -1, in: ids), 10)
    }

    func test_neighbor_wraps_around_both_ends() {
        let ids = [10, 20, 30]
        XCTAssertEqual(StationOrder.neighbor(of: 30, step: 1, in: ids), 10)
        XCTAssertEqual(StationOrder.neighbor(of: 10, step: -1, in: ids), 30)
        XCTAssertEqual(StationOrder.neighbor(of: 10, step: 4, in: ids), 20)
        XCTAssertEqual(StationOrder.neighbor(of: 10, step: -4, in: ids), 30)
    }

    func test_a_station_outside_the_list_enters_at_its_first_or_last_id() {
        let ids = [10, 20, 30]
        XCTAssertEqual(StationOrder.neighbor(of: 99, step: 1, in: ids), 10)
        XCTAssertEqual(StationOrder.neighbor(of: 99, step: -1, in: ids), 30)
    }

    func test_neighbor_is_nil_when_there_is_nowhere_else_to_go() {
        XCTAssertNil(StationOrder.neighbor(of: 10, step: 1, in: [10]))
        XCTAssertNil(StationOrder.neighbor(of: 10, step: -1, in: [10]))
        XCTAssertNil(StationOrder.neighbor(of: 10, step: 1, in: []))
        XCTAssertNil(StationOrder.neighbor(of: 10, step: 0, in: [10, 20]))
    }

    /// E6: "Postul următor" from Eldad went Eldad → Gosen → Suceava →
    /// Gosen → Eldad, because each play re-ranked the list it walked. The
    /// snapshot of the grid as shown is walked straight through instead.
    func test_stepping_through_a_snapshot_visits_every_station_once() {
        let snapshot = [1, 2, 3, 4, 5]
        var current = 1
        var visited = [current]
        for _ in 0..<5 {
            guard let next = StationOrder.neighbor(
                of: current, step: 1, in: snapshot
            ) else {
                return XCTFail("no next station after \(current)")
            }
            current = next
            visited.append(current)
        }
        XCTAssertEqual(visited, [1, 2, 3, 4, 5, 1])
    }

    // MARK: - neighbor(of:step:in:orElseIn:)

    private let posturi = [10, 20, 30, 40]

    func test_stepping_walks_the_grid_the_station_was_opened_from() {
        let favorites = [30, 10]
        XCTAssertEqual(
            StationOrder.neighbor(of: 30, step: 1, in: favorites,
                                  orElseIn: posturi),
            10
        )
        XCTAssertEqual(
            StationOrder.neighbor(of: 30, step: -1, in: favorites,
                                  orElseIn: posturi),
            10
        )
    }

    /// Review: opened from a one-card Favorite or Recente grid, previous
    /// and next did nothing. They walk "Posturi" instead.
    func test_a_station_alone_in_its_grid_steps_through_posturi() {
        XCTAssertEqual(
            StationOrder.neighbor(of: 20, step: 1, in: [20],
                                  orElseIn: posturi),
            30
        )
        XCTAssertEqual(
            StationOrder.neighbor(of: 20, step: -1, in: [20],
                                  orElseIn: posturi),
            10
        )
    }

    func test_a_station_outside_its_grid_steps_through_posturi() {
        XCTAssertEqual(
            StationOrder.neighbor(of: 30, step: 1, in: [20],
                                  orElseIn: posturi),
            40
        )
        XCTAssertEqual(
            StationOrder.neighbor(of: 30, step: 1, in: [],
                                  orElseIn: posturi),
            40
        )
    }

    func test_with_one_station_in_the_catalog_there_is_nowhere_to_go() {
        XCTAssertNil(
            StationOrder.neighbor(of: 20, step: 1, in: [20], orElseIn: [20])
        )
    }

    // MARK: - focusTarget(openedId:openedIndex:in:)

    func test_focus_returns_to_the_opened_card() {
        let target = StationOrder.focusTarget(
            openedId: 2, openedIndex: 1, in: [1, 2, 3]
        )
        XCTAssertEqual(target, 2)
    }

    func test_focus_goes_to_the_card_in_its_place_when_it_left() {
        let target = StationOrder.focusTarget(
            openedId: 2, openedIndex: 1, in: [1, 3]
        )
        XCTAssertEqual(target, 3)
    }

    func test_focus_clamps_to_the_last_card_when_the_list_shrank() {
        let target = StationOrder.focusTarget(
            openedId: 3, openedIndex: 2, in: [1, 2]
        )
        XCTAssertEqual(target, 2)
    }

    func test_focus_has_no_target_in_an_empty_list() {
        XCTAssertNil(
            StationOrder.focusTarget(openedId: 3, openedIndex: 0, in: [])
        )
    }

    // MARK: - Grid subtitle

    func test_station_count_follows_romanian_plural_rules() {
        XCTAssertEqual(RootView.stationCount(0), "0 posturi")
        XCTAssertEqual(RootView.stationCount(1), "1 post")
        XCTAssertEqual(RootView.stationCount(12), "12 posturi")
        XCTAssertEqual(RootView.stationCount(19), "19 posturi")
        XCTAssertEqual(RootView.stationCount(20), "20 de posturi")
        XCTAssertEqual(RootView.stationCount(64), "64 de posturi")
        XCTAssertEqual(RootView.stationCount(101), "101 posturi")
        XCTAssertEqual(RootView.stationCount(119), "119 posturi")
        XCTAssertEqual(RootView.stationCount(120), "120 de posturi")
    }
}
