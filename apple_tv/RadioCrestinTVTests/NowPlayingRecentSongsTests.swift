import XCTest
@testable import RadioCrestinTV

/// How "Melodii recente" says when each song started, counted back from
/// the moment the listener hears.
final class NowPlayingRecentSongsTests: XCTestCase {

    private let heardNow = Date(timeIntervalSince1970: 1_793_395_600)

    private func phrase(_ secondsBefore: TimeInterval) -> String {
        SongAge.phrase(
            startedAt: heardNow.addingTimeInterval(-secondsBefore),
            heardNow: heardNow
        )
    }

    func test_the_first_minute_reads_now() {
        XCTAssertEqual(phrase(0), "acum")
        XCTAssertEqual(phrase(59), "acum")
        // A start a moment past the heard one (the estimate before the
        // playhead is known) is just starting.
        XCTAssertEqual(phrase(-20), "acum")
    }

    func test_minutes_keep_their_short_form() {
        XCTAssertEqual(phrase(60), "acum 1 min")
        XCTAssertEqual(phrase(59 * 60 + 59), "acum 59 min")
    }

    /// Review C6: hours and days read "2h" and "3z"; "z" is no Romanian
    /// unit. Worded as on Android TV, with "de" from 20 on.
    func test_hours_are_spelled_out() {
        XCTAssertEqual(phrase(3600), "acum 1 oră")
        XCTAssertEqual(phrase(2 * 3600), "acum 2 ore")
        XCTAssertEqual(phrase(19 * 3600), "acum 19 ore")
        XCTAssertEqual(phrase(20 * 3600), "acum 20 de ore")
        XCTAssertEqual(phrase(23 * 3600 + 3599), "acum 23 de ore")
    }

    func test_days_are_spelled_out() {
        XCTAssertEqual(phrase(86_400), "acum 1 zi")
        XCTAssertEqual(phrase(3 * 86_400), "acum 3 zile")
        XCTAssertEqual(phrase(20 * 86_400), "acum 20 de zile")
    }
}
