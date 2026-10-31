import XCTest
@testable import RadioCrestinTV

final class RetryBackoffTests: XCTestCase {

    func test_default_schedule_doubles_from_2s_and_caps_at_30s() {
        let backoff = RetryBackoff()
        let delays = (1...8).map { backoff.delay(afterFailedRounds: $0) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30, 30, 30])
    }

    func test_no_failed_round_yet_waits_the_initial_delay() {
        let backoff = RetryBackoff()
        XCTAssertEqual(backoff.delay(afterFailedRounds: 0), 2)
        XCTAssertEqual(backoff.delay(afterFailedRounds: -3), 2)
    }

    func test_a_very_long_outage_stays_on_the_cap() {
        let backoff = RetryBackoff()
        XCTAssertEqual(backoff.delay(afterFailedRounds: 10_000), 30)
        XCTAssertEqual(backoff.delay(afterFailedRounds: .max), 30)
    }

    func test_custom_schedule() {
        let backoff = RetryBackoff(initialDelay: 1, maximumDelay: 5)
        let delays = (1...5).map { backoff.delay(afterFailedRounds: $0) }
        XCTAssertEqual(delays, [1, 2, 4, 5, 5])
    }
}
