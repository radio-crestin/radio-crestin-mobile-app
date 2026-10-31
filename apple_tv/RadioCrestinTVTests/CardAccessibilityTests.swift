import XCTest
@testable import RadioCrestinTV

/// What VoiceOver reads of a station card's corner badges, after its name
/// and song.
final class CardAccessibilityTests: XCTestCase {

    func test_a_card_without_badges_has_no_value() {
        XCTAssertEqual(
            StationCard.accessibilityState(
                playback: .notCurrent, isFavorite: false
            ),
            ""
        )
    }

    func test_the_playing_station_says_so() {
        XCTAssertEqual(
            StationCard.accessibilityState(
                playback: .playing, isFavorite: false
            ),
            "se redă acum"
        )
    }

    /// The badge stays on the paused station's card; VoiceOver must not
    /// say it plays.
    func test_the_paused_station_says_it_is_paused() {
        XCTAssertEqual(
            StationCard.accessibilityState(
                playback: .paused, isFavorite: false
            ),
            "în pauză"
        )
    }

    func test_a_favourite_says_so() {
        XCTAssertEqual(
            StationCard.accessibilityState(
                playback: .notCurrent, isFavorite: true
            ),
            "favorit"
        )
    }

    /// In the badges' order on screen: the playing one left of the heart.
    func test_a_playing_favourite_says_both() {
        XCTAssertEqual(
            StationCard.accessibilityState(
                playback: .playing, isFavorite: true
            ),
            "se redă acum, favorit"
        )
    }

    func test_a_paused_favourite_says_both() {
        XCTAssertEqual(
            StationCard.accessibilityState(
                playback: .paused, isFavorite: true
            ),
            "în pauză, favorit"
        )
    }
}

/// Which card marks the current station, and how.
final class CardPlaybackTests: XCTestCase {

    func test_the_current_station_plays_until_paused() {
        XCTAssertEqual(
            StationCard.Playback(isCurrent: true, isPaused: false),
            .playing
        )
        XCTAssertEqual(
            StationCard.Playback(isCurrent: true, isPaused: true),
            .paused
        )
    }

    /// The pause belongs to the current station: the other cards show
    /// no badge, paused or not.
    func test_other_stations_are_never_marked() {
        XCTAssertEqual(
            StationCard.Playback(isCurrent: false, isPaused: false),
            .notCurrent
        )
        XCTAssertEqual(
            StationCard.Playback(isCurrent: false, isPaused: true),
            .notCurrent
        )
    }
}
