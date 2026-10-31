import XCTest
@testable import RadioCrestinTV

/// The song changes of an HLS item, as the origin announces them: each
/// song's `EXT-X-DATERANGE` once it ended, with its START-DATE and
/// END-DATE, the end being the start of the next song.
final class SongBoundariesTests: XCTestCase {
    /// Seconds on the broadcast timeline as a date.
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_793_400_000 + seconds)
    }

    /// The dates of one DATERANGE group.
    private func song(
        from start: TimeInterval, to end: TimeInterval
    ) -> [Date] {
        [at(start), at(end)]
    }

    func test_the_changes_before_the_audio_started_are_never_reached() {
        var boundaries = SongBoundaries()
        boundaries.add(song(from: 0, to: 230) + song(from: 230, to: 500))

        XCTAssertFalse(boundaries.reach(at(520)), "the start")
        XCTAssertFalse(boundaries.reach(at(521)))
        XCTAssertFalse(boundaries.reach(at(600)))
    }

    /// 2-minute mode: the song now on air started live 60 s ago, so its
    /// start is still 60 s ahead of the listener.
    func test_a_change_ahead_of_the_start_is_reached_once_when_the_audio_gets_there() {
        var boundaries = SongBoundaries()
        boundaries.add(song(from: 0, to: 230) + song(from: 230, to: 500))
        XCTAssertFalse(boundaries.reach(at(440)))

        XCTAssertFalse(boundaries.reach(at(499.9)))
        XCTAssertTrue(boundaries.reach(at(500)))
        XCTAssertFalse(boundaries.reach(at(501)), "once")
    }

    /// Live: the song on air ends, its tag appears at the live edge 18 s
    /// before the listener hears that moment.
    func test_a_change_announced_later_is_reached_when_the_audio_gets_there() {
        var boundaries = SongBoundaries()
        boundaries.add(song(from: 0, to: 230))
        XCTAssertFalse(boundaries.reach(at(250)))

        boundaries.add(song(from: 230, to: 470))
        XCTAssertFalse(boundaries.reach(at(460)))
        XCTAssertTrue(boundaries.reach(at(470.4)))
    }

    /// A change the audio passed before the playlist announced it (a
    /// playlist loaded late) still changes the song on screen.
    func test_a_change_announced_after_the_audio_passed_it_is_reached_at_once() {
        var boundaries = SongBoundaries()
        XCTAssertFalse(boundaries.reach(at(100)))
        XCTAssertFalse(boundaries.reach(at(130)))

        boundaries.add(song(from: 0, to: 120))

        XCTAssertTrue(boundaries.reach(at(131)))
    }

    func test_a_song_end_and_the_next_start_are_one_change_and_a_group_seen_again_counts_once() {
        var boundaries = SongBoundaries()
        boundaries.add(song(from: 0, to: 230))
        XCTAssertFalse(boundaries.reach(at(100)))
        // The next song's group, its start 0.4 s off the previous end.
        boundaries.add([at(230.4), at(470)])
        boundaries.add(song(from: 0, to: 230))

        XCTAssertTrue(boundaries.reach(at(231)))
        XCTAssertFalse(boundaries.reach(at(300)), "not again for 230.4")
        XCTAssertTrue(boundaries.reach(at(470)))
    }

    func test_several_changes_passed_at_once_are_one_reach() {
        var boundaries = SongBoundaries()
        boundaries.add(song(from: 0, to: 120) + song(from: 120, to: 135))
        XCTAssertFalse(boundaries.reach(at(100)))

        XCTAssertTrue(boundaries.reach(at(140)))
        XCTAssertFalse(boundaries.reach(at(141)))
    }

    /// The fetch a change triggers asks about the moment after it.
    func test_the_latest_change_at_or_before_the_audio() {
        var boundaries = SongBoundaries()
        boundaries.add(song(from: 0, to: 230) + song(from: 230, to: 470))

        XCTAssertNil(boundaries.latest(atOrBefore: at(-1)))
        XCTAssertEqual(boundaries.latest(atOrBefore: at(229)), at(0))
        XCTAssertEqual(boundaries.latest(atOrBefore: at(230)), at(230))
        XCTAssertEqual(boundaries.latest(atOrBefore: at(1_000)), at(470))
    }

    func test_only_the_newest_boundaries_are_remembered() {
        var boundaries = SongBoundaries()
        let count = SongBoundaries.capacity + 10
        boundaries.add((0..<count).map { at(TimeInterval($0) * 10) })

        XCTAssertNil(boundaries.latest(atOrBefore: at(5)), "forgotten")
        XCTAssertEqual(
            boundaries.latest(atOrBefore: at(1_000_000)),
            at(TimeInterval(count - 1) * 10)
        )
    }
}
