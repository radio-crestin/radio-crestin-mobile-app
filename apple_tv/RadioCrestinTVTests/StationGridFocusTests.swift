import XCTest
@testable import RadioCrestinTV

/// Guards the grid's initial-focus contract: focus enters at the first
/// card of the frozen display order, unless the user already focused a
/// card in that grid this session — in which case that card is restored.
final class StationGridFocusTests: XCTestCase {

    private func station(id: Int, slug: String) -> Station {
        Station(
            id: id, slug: slug, title: slug, order: 0,
            thumbnailUrl: nil, totalListeners: 0,
            stationStreams: [
                StationStream(order: 0, type: "HLS", streamUrl: "https://x/\(slug)")
            ],
            uptime: nil, nowPlaying: nil,
            reviewsStats: ReviewsStats(averageRating: 0, numberOfReviews: 0),
            stationType: nil, playlistItems: nil, hlsDvrStreamUrl: nil
        )
    }

    private var sample: [Station] {
        (1...5).map { station(id: $0, slug: "s\($0)") }
    }

    func test_first_entry_targets_the_first_station_in_display_order() {
        XCTAssertEqual(
            StationGridFocus.defaultTargetId(
                lastFocusedId: nil, stations: sample
            ),
            1,
            "with no session memory focus must start at the first card"
        )
    }

    func test_first_entry_follows_the_given_order_not_the_lowest_id() {
        let reordered = sample.reversed().map { $0 }
        XCTAssertEqual(
            StationGridFocus.defaultTargetId(
                lastFocusedId: nil, stations: reordered
            ),
            5,
            "the array order is the frozen display order — id is irrelevant"
        )
    }

    func test_a_previously_focused_card_is_restored() {
        XCTAssertEqual(
            StationGridFocus.defaultTargetId(
                lastFocusedId: 4, stations: sample
            ),
            4
        )
    }

    func test_a_remembered_card_that_left_the_list_falls_back_to_the_first() {
        // e.g. the user unfavourited the station they had focused, so it
        // is no longer in the Favorite grid.
        XCTAssertEqual(
            StationGridFocus.defaultTargetId(
                lastFocusedId: 99, stations: sample
            ),
            1
        )
    }

    func test_an_empty_grid_has_no_focus_target() {
        XCTAssertNil(
            StationGridFocus.defaultTargetId(lastFocusedId: nil, stations: [])
        )
        XCTAssertNil(
            StationGridFocus.defaultTargetId(lastFocusedId: 3, stations: [])
        )
    }
}
