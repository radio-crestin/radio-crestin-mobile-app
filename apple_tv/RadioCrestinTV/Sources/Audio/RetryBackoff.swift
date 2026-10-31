import Foundation

/// How long the audio engine waits before another round over a station's
/// streams, once every one of them failed.
///
/// The wait starts short so a brief outage (a Wi-Fi roam, a server
/// restart) is over in a couple of seconds, doubles so a station that stays
/// down is not hammered by every Apple TV tuned to it, and is capped so the
/// listener hears the station again at most ~30 s after it comes back. A
/// network path that becomes usable again skips the wait altogether (see
/// `LiveStreamSupervisor.networkBecameAvailable`).
struct RetryBackoff: Equatable {
    /// Wait after the first failed round. Two seconds is long enough not to
    /// spin on a stream that fails instantly (no network: every request
    /// fails within milliseconds) and short enough to feel immediate.
    var initialDelay: TimeInterval = 2

    /// Upper bound of the wait. Thirty seconds keeps at most one round per
    /// half minute per listener against a station that is down, and keeps
    /// the silence after it comes back short.
    var maximumDelay: TimeInterval = 30

    /// The wait after `failedRounds` consecutive failed rounds (1 for the
    /// first): 2, 4, 8, 16, then 30 s for every round after.
    func delay(afterFailedRounds failedRounds: Int) -> TimeInterval {
        let doublings = Double(max(failedRounds - 1, 0))
        // `pow` saturates to infinity instead of overflowing, so a very
        // long outage still lands on the cap.
        return min(initialDelay * pow(2, doublings), maximumDelay)
    }
}
