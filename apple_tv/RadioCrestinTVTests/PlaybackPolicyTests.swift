import XCTest
@testable import RadioCrestinTV

/// Covers the pure playback-UX decisions in `PlaybackPolicy.swift`:
/// playlist edge navigation, the connect-timeout bound, and the video
/// controls auto-hide rule.
final class PlaybackPolicyTests: XCTestCase {

    // MARK: - Playlist edge navigation: next

    func test_next_inside_playlist_advances_one_item() {
        XCTAssertEqual(
            PlaylistEdgePolicy.next(index: 0, count: 4), .item(1)
        )
        XCTAssertEqual(
            PlaylistEdgePolicy.next(index: 2, count: 4), .item(3)
        )
    }

    func test_next_on_last_item_advances_to_the_next_station() {
        XCTAssertEqual(
            PlaylistEdgePolicy.next(index: 3, count: 4), .nextStation
        )
    }

    func test_next_on_single_item_playlist_advances_station() {
        XCTAssertEqual(
            PlaylistEdgePolicy.next(index: 0, count: 1), .nextStation
        )
    }

    func test_next_never_wraps_back_to_the_first_item() {
        // The old behavior was `(index + 1) % count`, which returned 0.
        XCTAssertNotEqual(
            PlaylistEdgePolicy.next(index: 4, count: 5), .item(0)
        )
    }

    // MARK: - Playlist edge navigation: previous

    func test_previous_inside_playlist_steps_back_one_item() {
        XCTAssertEqual(
            PlaylistEdgePolicy.previous(index: 3, count: 4), .item(2)
        )
        XCTAssertEqual(
            PlaylistEdgePolicy.previous(index: 1, count: 4), .item(0)
        )
    }

    func test_previous_on_first_item_goes_to_the_previous_station() {
        XCTAssertEqual(
            PlaylistEdgePolicy.previous(index: 0, count: 4), .previousStation
        )
    }

    func test_previous_never_wraps_to_the_last_item() {
        XCTAssertNotEqual(
            PlaylistEdgePolicy.previous(index: 0, count: 5), .item(4)
        )
    }

    // MARK: - Edge / defensive cases

    func test_empty_playlist_navigates_nowhere() {
        XCTAssertEqual(PlaylistEdgePolicy.next(index: 0, count: 0), .none)
        XCTAssertEqual(PlaylistEdgePolicy.previous(index: 0, count: 0), .none)
    }

    func test_out_of_range_indices_are_clamped_into_the_list() {
        // A stale index (list shrank under a live sync) must still land on
        // a real item rather than crossing a station boundary by accident.
        XCTAssertEqual(PlaylistEdgePolicy.next(index: -3, count: 4), .item(0))
        XCTAssertEqual(
            PlaylistEdgePolicy.previous(index: 9, count: 4), .item(3)
        )
    }

    // MARK: - Connect timeout

    func test_connect_timeout_budget_is_ten_seconds() {
        XCTAssertEqual(PlaybackTimeoutPolicy.connectTimeout, 10)
    }

    func test_still_connecting_under_budget_does_not_time_out() {
        XCTAssertFalse(
            PlaybackTimeoutPolicy.hasTimedOut(isConnecting: true, elapsed: 0)
        )
        XCTAssertFalse(
            PlaybackTimeoutPolicy.hasTimedOut(isConnecting: true, elapsed: 9.9)
        )
    }

    func test_still_connecting_at_or_past_budget_times_out() {
        XCTAssertTrue(
            PlaybackTimeoutPolicy.hasTimedOut(isConnecting: true, elapsed: 10)
        )
        XCTAssertTrue(
            PlaybackTimeoutPolicy.hasTimedOut(isConnecting: true, elapsed: 45)
        )
    }

    func test_playing_stream_never_times_out_however_long_it_runs() {
        XCTAssertFalse(
            PlaybackTimeoutPolicy.hasTimedOut(
                isConnecting: false, elapsed: 3_600
            )
        )
    }

    // MARK: - Controls auto-hide

    func test_auto_hide_idle_window_is_twenty_seconds() {
        XCTAssertEqual(ControlsAutoHidePolicy.idleTimeout, 20)
    }

    func test_controls_auto_hide_while_playing() {
        XCTAssertTrue(
            ControlsAutoHidePolicy.shouldAutoHide(
                isPlaying: true, hasError: false
            )
        )
    }

    func test_controls_stay_visible_while_paused() {
        XCTAssertFalse(
            ControlsAutoHidePolicy.shouldAutoHide(
                isPlaying: false, hasError: false
            )
        )
    }

    func test_controls_stay_visible_while_an_error_is_showing() {
        XCTAssertFalse(
            ControlsAutoHidePolicy.shouldAutoHide(
                isPlaying: true, hasError: true
            )
        )
    }
}
