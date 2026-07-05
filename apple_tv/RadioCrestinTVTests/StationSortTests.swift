import XCTest
@testable import RadioCrestinTV

final class StationSortTests: XCTestCase {

    private func station(
        slug: String,
        title: String,
        listeners: Int? = 0,
        avgRating: Double = 0,
        reviewCount: Int = 0,
        id: Int? = nil
    ) -> Station {
        Station(
            id: id ?? abs(slug.hashValue),
            slug: slug,
            title: title,
            order: 0,
            thumbnailUrl: nil,
            totalListeners: listeners,
            stationStreams: [
                StationStream(order: 0, type: "MP3",
                              streamUrl: "https://x/\(slug)"),
            ],
            uptime: Uptime(isUp: true, timestamp: nil),
            nowPlaying: nil,
            reviewsStats: ReviewsStats(
                averageRating: avgRating,
                numberOfReviews: reviewCount
            ),
            stationType: nil,
            playlistItems: nil
        )
    }

    // MARK: - Alphabetical

    func test_alphabetical_uses_locale_insensitive_compare() {
        let stations = [
            station(slug: "z", title: "Zenith"),
            station(slug: "a", title: "Älska"),
            station(slug: "b", title: "Beta"),
        ]
        let sorted = StationSortService.sort(
            stations, by: .alphabetical,
            playCounts: [:], favoriteSlugs: []
        )
        XCTAssertEqual(sorted.map(\.title), ["Älska", "Beta", "Zenith"])
    }

    func test_alphabetical_is_case_insensitive() {
        let stations = [
            station(slug: "x", title: "alpha"),
            station(slug: "y", title: "Beta"),
            station(slug: "z", title: "GAMMA"),
        ]
        let sorted = StationSortService.sort(
            stations, by: .alphabetical,
            playCounts: [:], favoriteSlugs: []
        )
        XCTAssertEqual(sorted.map(\.title), ["alpha", "Beta", "GAMMA"])
    }

    // MARK: - Listeners

    func test_listeners_sort_descending_with_nil_treated_as_zero() {
        let stations = [
            station(slug: "a", title: "A", listeners: 5),
            station(slug: "b", title: "B", listeners: nil),
            station(slug: "c", title: "C", listeners: 100),
            station(slug: "d", title: "D", listeners: 20),
        ]
        let sorted = StationSortService.sort(
            stations, by: .listeners,
            playCounts: [:], favoriteSlugs: []
        )
        XCTAssertEqual(sorted.map(\.slug), ["c", "d", "a", "b"])
    }

    // MARK: - Most played

    func test_mostPlayed_orders_by_play_count_desc() {
        let stations = [
            station(slug: "a", title: "A", listeners: 10, avgRating: 5,
                    reviewCount: 1),
            station(slug: "b", title: "B", listeners: 1),
            station(slug: "c", title: "C", listeners: 1),
        ]
        let sorted = StationSortService.sort(
            stations, by: .mostPlayed,
            playCounts: ["b": 10, "c": 5, "a": 1],
            favoriteSlugs: []
        )
        XCTAssertEqual(sorted.map(\.slug), ["b", "c", "a"])
    }

    func test_mostPlayed_breaks_ties_by_score_when_no_plays() {
        let stations = [
            station(slug: "a", title: "A", listeners: 0,
                    avgRating: 1, reviewCount: 1),  // low score
            station(slug: "b", title: "B", listeners: 100,
                    avgRating: 5, reviewCount: 10), // high score
        ]
        // Equal play counts → tie-break by score (b wins).
        let sorted = StationSortService.sort(
            stations, by: .mostPlayed,
            playCounts: [:],
            favoriteSlugs: []
        )
        XCTAssertEqual(sorted.first?.slug, "b")
    }

    // MARK: - Recommended

    func test_recommended_returns_empty_for_empty_input() {
        let sorted = StationSortService.sort(
            [], by: .recommended,
            playCounts: [:], favoriteSlugs: []
        )
        XCTAssertEqual(sorted.count, 0)
    }

    func test_recommended_starts_with_station_of_the_day() {
        let stations = [
            station(slug: "alpha", title: "Alpha", listeners: 1),
            station(slug: "bravo", title: "Bravo", listeners: 2),
            station(slug: "charlie", title: "Charlie", listeners: 3),
        ]
        let sorted = StationSortService.sort(
            stations, by: .recommended,
            playCounts: [:], favoriteSlugs: []
        )
        // Whatever station-of-day is, it must be first.
        XCTAssertEqual(sorted.count, stations.count)
        let stationOfDay = sorted.first!.slug
        XCTAssertTrue(["alpha", "bravo", "charlie"].contains(stationOfDay))
    }

    func test_recommended_promotes_top_3_played() {
        let stations = (0..<10).map {
            station(slug: "s\($0)", title: "S\($0)", listeners: 0)
        }
        let plays = ["s7": 100, "s4": 50, "s2": 25, "s9": 5]

        let sorted = StationSortService.sort(
            stations, by: .recommended,
            playCounts: plays,
            favoriteSlugs: []
        )

        // Top three played slugs (excluding station of day & favorites)
        // must appear in positions 1..3.
        let top3 = Array(sorted[1...3]).map(\.slug)
        let stationOfDay = sorted[0].slug
        let expected = ["s7", "s4", "s2"].filter { $0 != stationOfDay }
        for s in expected {
            XCTAssertTrue(top3.contains(s),
                          "expected \(s) in top 3 (got \(top3))")
        }
    }

    func test_recommended_excludes_favorites_from_top3() {
        let stations = (0..<10).map {
            station(slug: "s\($0)", title: "S\($0)", listeners: 0)
        }
        // s7 is most-played but also a favorite — should not appear in top3.
        let plays = ["s7": 100, "s4": 50, "s2": 25]
        let sorted = StationSortService.sort(
            stations, by: .recommended,
            playCounts: plays,
            favoriteSlugs: ["s7"]
        )
        let top3 = Array(sorted[1...3]).map(\.slug)
        XCTAssertFalse(top3.contains("s7"))
    }

    // MARK: - Private stations pinned first

    func test_private_stations_pin_first_in_alphabetical() {
        let stations = [
            station(slug: "a", title: "Alpha", id: 1),
            station(slug: "z", title: "Zulu (privat)", id: 100),
            station(slug: "b", title: "Beta", id: 2),
            station(slug: "m", title: "Mike (privat)", id: 101),
        ]
        let sorted = StationSortService.sort(
            stations, by: .alphabetical,
            playCounts: [:], favoriteSlugs: [],
            privateIds: [100, 101]
        )
        // Private block first (alphabetical among themselves), then the
        // public stations alphabetically.
        XCTAssertEqual(sorted.map(\.id), [101, 100, 1, 2])
    }

    func test_private_stations_pin_first_in_listeners_sort() {
        let stations = [
            station(slug: "pub-big", title: "P", listeners: 500, id: 1),
            station(slug: "priv-small", title: "S", listeners: 1, id: 100),
        ]
        let sorted = StationSortService.sort(
            stations, by: .listeners,
            playCounts: [:], favoriteSlugs: [],
            privateIds: [100]
        )
        // Even with far fewer listeners, the private station pins first.
        XCTAssertEqual(sorted.map(\.id), [100, 1])
    }

    func test_no_private_ids_leaves_order_unchanged() {
        let stations = [
            station(slug: "b", title: "Beta"),
            station(slug: "a", title: "Alpha"),
        ]
        let withDefault = StationSortService.sort(
            stations, by: .alphabetical,
            playCounts: [:], favoriteSlugs: []
        )
        let withEmpty = StationSortService.sort(
            stations, by: .alphabetical,
            playCounts: [:], favoriteSlugs: [],
            privateIds: []
        )
        XCTAssertEqual(withDefault.map(\.slug), withEmpty.map(\.slug))
    }

    // MARK: - Score snapshot

    func test_scoreSnapshot_normalizes_against_max() {
        let stations = [
            station(slug: "a", title: "A", listeners: 10,
                    avgRating: 4, reviewCount: 5), // reviewScore=20
            station(slug: "b", title: "B", listeners: 100,
                    avgRating: 5, reviewCount: 10), // reviewScore=50
        ]
        let snap = StationSortService.scoreSnapshot(for: stations)
        // b has the max review and listener count → score should be 1.0.
        XCTAssertEqual(snap["b"]?.score ?? 0, 1.0, accuracy: 0.001)
        // a is half listeners (10/100) and 0.4 of reviews (20/50)
        // → (0.4 * 0.5) + (0.1 * 0.5) = 0.25.
        XCTAssertEqual(snap["a"]?.score ?? 0, 0.25, accuracy: 0.001)
    }

    func test_scoreSnapshot_returns_empty_for_empty_input() {
        let snap = StationSortService.scoreSnapshot(for: [])
        XCTAssertTrue(snap.isEmpty)
    }
}
