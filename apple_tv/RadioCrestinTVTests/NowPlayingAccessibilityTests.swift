import XCTest
@testable import RadioCrestinTV

/// What VoiceOver reads for Now Playing's listener count and rating.
final class NowPlayingAccessibilityTests: XCTestCase {

    private func listeners(_ count: Int) -> String {
        RomanianCount.phrase(count, one: "ascultător", many: "ascultători")
    }

    func test_one_listener_is_singular() {
        XCTAssertEqual(listeners(1), "1 ascultător")
    }

    func test_up_to_nineteen_listeners_take_no_de() {
        XCTAssertEqual(listeners(2), "2 ascultători")
        XCTAssertEqual(listeners(19), "19 ascultători")
    }

    func test_from_twenty_listeners_take_de() {
        XCTAssertEqual(listeners(20), "20 de ascultători")
        XCTAssertEqual(listeners(57), "57 de ascultători")
        XCTAssertEqual(listeners(100), "100 de ascultători")
    }

    /// Romanian follows the last two digits: 101–119 read like 1–19.
    func test_hundreds_follow_their_last_two_digits() {
        XCTAssertEqual(listeners(101), "101 ascultători")
        XCTAssertEqual(listeners(119), "119 ascultători")
        XCTAssertEqual(listeners(120), "120 de ascultători")
        XCTAssertEqual(listeners(1_000), "1000 de ascultători")
    }

    func test_the_rating_reads_as_one_romanian_sentence() {
        let stars = RatingStars(rating: 4.83, count: 215)
        XCTAssertEqual(
            stars.accessibilityDescription,
            "Evaluare 4,8 din 5, 215 recenzii"
        )
    }

    func test_the_rating_counts_its_reviews_in_romanian() {
        XCTAssertEqual(
            RatingStars(rating: 5, count: 1).accessibilityDescription,
            "Evaluare 5 din 5, 1 recenzie"
        )
        XCTAssertEqual(
            RatingStars(rating: 4.3, count: 45).accessibilityDescription,
            "Evaluare 4,3 din 5, 45 de recenzii"
        )
    }

    func test_a_rating_without_reviews_reads_the_average_alone() {
        XCTAssertEqual(
            RatingStars(rating: 4.5, count: 0).accessibilityDescription,
            "Evaluare 4,5 din 5"
        )
    }
}
