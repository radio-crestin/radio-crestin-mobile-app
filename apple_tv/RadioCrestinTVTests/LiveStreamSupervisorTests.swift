import AVFoundation
import XCTest
@testable import RadioCrestinTV

/// Every rule of the live stream supervisor, driven with an explicit clock
/// (seconds) and the default thresholds: 10 s connect timeout (20 s after a
/// failed round), 10 s stall timeout, 30 s of playback to end an outage,
/// 60 s of lag behind live at an HLS join, backoff 2, 4, 8, 16, 30 s.
final class LiveStreamSupervisorTests: XCTestCase {
    private typealias Supervisor = LiveStreamSupervisor

    // MARK: - Helpers

    private func playing(_ playhead: Double) -> Supervisor.Sample {
        .init(status: .playing, playhead: playhead)
    }

    private func buffering(_ playhead: Double? = nil) -> Supervisor.Sample {
        .init(status: .buffering, playhead: playhead)
    }

    private func paused(_ playhead: Double? = nil) -> Supervisor.Sample {
        .init(status: .paused, playhead: playhead)
    }

    private func deciding(_ playhead: Double? = nil) -> Supervisor.Sample {
        .init(status: .deciding, playhead: playhead)
    }

    /// The attempt id of a `.load` of `stream`, or a failure for anything
    /// else.
    private func attempt(
        loadedBy action: Supervisor.Action,
        stream expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        guard case .load(let stream, let attempt) = action else {
            XCTFail("expected a load of stream \(expected), got \(action)",
                    file: file, line: line)
            return -1
        }
        XCTAssertEqual(stream, expected, file: file, line: line)
        return attempt
    }

    /// Starts `supervisor` at t = 0 on `streams` streams and returns its
    /// first attempt.
    private func start(
        _ supervisor: inout Supervisor,
        streams: Int = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        attempt(
            loadedBy: supervisor.start(streamCount: streams, at: 0),
            stream: 0, file: file, line: line
        )
    }

    /// One look per second of steady playback, from `start` to `end`
    /// inclusive, the playhead moving with the clock (`offset` behind it).
    /// Every look must leave the stream alone.
    private func playSteadily(
        _ supervisor: inout Supervisor,
        attempt: Int,
        from start: TimeInterval,
        to end: TimeInterval,
        playheadOffset offset: Double = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for time in stride(from: start, through: end, by: 1) {
            let action = supervisor.record(
                playing(time - offset), attempt: attempt, at: time
            )
            XCTAssertEqual(action, .none, "at \(time)", file: file, line: line)
        }
    }

    /// Fails both streams of a two-stream round that starts with
    /// `attempt`, and returns the resulting action.
    private func failRound(
        _ supervisor: inout Supervisor,
        startingWith attempt: Int,
        at time: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Supervisor.Action {
        let fallback = self.attempt(
            loadedBy: supervisor.attemptFailed(attempt, at: time),
            stream: 1, file: file, line: line
        )
        return supervisor.attemptFailed(fallback, at: time)
    }

    // MARK: - Start

    func test_start_loads_the_first_stream_and_shows_connecting() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        XCTAssertEqual(supervisor.currentAttempt, attempt)
        XCTAssertEqual(supervisor.display, .connecting)
        XCTAssertTrue(supervisor.wantsAudio)
        XCTAssertNil(supervisor.lastGiveUpReason)
    }

    func test_start_without_streams_stays_stopped() {
        var supervisor = Supervisor()
        XCTAssertEqual(supervisor.start(streamCount: 0, at: 0), .none)
        XCTAssertFalse(supervisor.wantsAudio)
        XCTAssertNil(supervisor.display)
        XCTAssertEqual(supervisor.tick(at: 100), .none)
    }

    func test_attempt_ids_stay_unique_across_play_requests() {
        var supervisor = Supervisor()
        let first = start(&supervisor)
        supervisor.stop()
        let second = attempt(
            loadedBy: supervisor.start(streamCount: 2, at: 50), stream: 0
        )
        XCTAssertNotEqual(first, second)
        // A late callback of the first request must not reach the second.
        XCTAssertEqual(supervisor.attemptFailed(first, at: 51), .none)
        XCTAssertEqual(supervisor.currentAttempt, second)
    }

    // MARK: - Connect timeout

    func test_an_attempt_that_does_not_start_in_10s_moves_to_the_next_stream() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        XCTAssertEqual(
            supervisor.record(buffering(), attempt: attempt, at: 5), .none
        )
        XCTAssertEqual(supervisor.tick(at: 9.9), .none)

        let next = supervisor.tick(at: 10)

        _ = self.attempt(loadedBy: next, stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .noStart)
        XCTAssertEqual(supervisor.display, .connecting)
    }

    /// E1: timeControlStatus flicked to playing and back while the item
    /// was ready and the playhead never moved — silence, not a start.
    func test_a_ready_item_whose_playhead_never_moves_is_not_a_start() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = supervisor.record(paused(0), attempt: attempt, at: 0.50)
        _ = supervisor.record(playing(0), attempt: attempt, at: 0.52)
        XCTAssertEqual(supervisor.display, .playing)
        _ = supervisor.record(paused(0), attempt: attempt, at: 0.54)
        XCTAssertEqual(supervisor.display, .connecting)
        for time in stride(from: 1.0, through: 9, by: 1) {
            XCTAssertEqual(
                supervisor.record(paused(0), attempt: attempt, at: time), .none
            )
        }

        let next = supervisor.record(paused(0), attempt: attempt, at: 10)

        _ = self.attempt(loadedBy: next, stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .noStart)
    }

    func test_playing_without_playhead_progress_is_not_a_start() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        for time in stride(from: 1.0, through: 9, by: 1) {
            _ = supervisor.record(playing(5), attempt: attempt, at: time)
        }
        // AVPlayer says playing, so the listener is told so (truthful
        // state) — but without progress the attempt never started.
        XCTAssertEqual(supervisor.display, .playing)

        let next = supervisor.record(playing(5), attempt: attempt, at: 10)

        _ = self.attempt(loadedBy: next, stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .noStart)
    }

    func test_a_playhead_jump_while_loading_is_not_a_start() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = supervisor.record(buffering(0), attempt: attempt, at: 1)
        // HLS join: the playhead lands 12 s into the live window.
        _ = supervisor.record(buffering(12), attempt: attempt, at: 2)
        _ = supervisor.record(playing(12), attempt: attempt, at: 3)
        for time in stride(from: 4.0, through: 9, by: 1) {
            _ = supervisor.record(playing(12), attempt: attempt, at: time)
        }

        let next = supervisor.tick(at: 10)

        _ = self.attempt(loadedBy: next, stream: 1)
    }

    func test_a_start_cancels_the_connect_timeout() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = supervisor.record(playing(12), attempt: attempt, at: 3)
        _ = supervisor.record(playing(13), attempt: attempt, at: 4)

        // Started at 4: only a stall can end it now, 10 s after the last
        // progress.
        XCTAssertEqual(supervisor.tick(at: 10), .none)
        XCTAssertEqual(supervisor.tick(at: 13.9), .none)
        _ = self.attempt(loadedBy: supervisor.tick(at: 14), stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .stalled)
    }

    func test_later_rounds_give_a_stream_20s_to_start() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        XCTAssertEqual(
            failRound(&supervisor, startingWith: attempt, at: 1),
            .waitForRetry(delay: 2, report: true)
        )
        let retry = self.attempt(loadedBy: supervisor.tick(at: 3), stream: 0)

        XCTAssertEqual(
            supervisor.record(buffering(), attempt: retry, at: 13), .none
        )
        XCTAssertEqual(supervisor.tick(at: 22.9), .none)
        _ = self.attempt(loadedBy: supervisor.tick(at: 23), stream: 1)
    }

    // MARK: - Stall

    func test_a_started_stream_that_stands_still_for_10s_moves_on() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        playSteadily(&supervisor, attempt: attempt, from: 0, to: 5)

        XCTAssertEqual(
            supervisor.record(buffering(5), attempt: attempt, at: 6), .none
        )
        XCTAssertEqual(supervisor.display, .connecting)
        XCTAssertEqual(
            supervisor.record(buffering(5), attempt: attempt, at: 14.9), .none
        )

        let next = supervisor.record(buffering(5), attempt: attempt, at: 15)

        _ = self.attempt(loadedBy: next, stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .stalled)
    }

    func test_a_stream_that_recovers_before_10s_is_kept() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        playSteadily(&supervisor, attempt: attempt, from: 0, to: 5)
        for time in stride(from: 6.0, through: 13, by: 1) {
            XCTAssertEqual(
                supervisor.record(buffering(5), attempt: attempt, at: time),
                .none
            )
        }
        XCTAssertEqual(supervisor.display, .connecting)

        // Playing again at 14 (playhead still 5), advancing from 15 on.
        playSteadily(
            &supervisor, attempt: attempt, from: 14, to: 60, playheadOffset: 9
        )

        XCTAssertEqual(supervisor.display, .playing)
        XCTAssertEqual(supervisor.currentAttempt, attempt)
        XCTAssertNil(supervisor.lastGiveUpReason)
    }

    func test_evaluating_buffering_rate_changes_neither_display_nor_progress() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = supervisor.record(deciding(0), attempt: attempt, at: 0.2)
        XCTAssertEqual(supervisor.display, .connecting)

        _ = supervisor.record(playing(1), attempt: attempt, at: 1)
        _ = supervisor.record(deciding(1.5), attempt: attempt, at: 1.5)
        XCTAssertEqual(supervisor.display, .playing)
        // Progress from 1 to 2 still counts across the brief wait.
        _ = supervisor.record(playing(2), attempt: attempt, at: 2)

        XCTAssertEqual(supervisor.tick(at: 11.9), .none)
        _ = self.attempt(loadedBy: supervisor.tick(at: 12), stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .stalled)
    }

    // MARK: - AVPlayer failures

    /// E3: HLS 404 at start fails the item at once; MP3 follows.
    func test_an_item_failure_moves_to_the_next_stream_at_once() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)

        let next = supervisor.attemptFailed(attempt, at: 0.03)

        _ = self.attempt(loadedBy: next, stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .failed)
        XCTAssertEqual(supervisor.display, .connecting)
    }

    func test_failed_to_play_to_end_mid_play_moves_on_at_once() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        playSteadily(&supervisor, attempt: attempt, from: 0, to: 30)

        let next = supervisor.attemptFailed(attempt, at: 30.5)

        _ = self.attempt(loadedBy: next, stream: 1)
    }

    /// E2a: the HLS origin vanishes mid-play. The buffer drains, AVPlayer
    /// waits; the supervisor moves to MP3 after 10 s, long before AVPlayer
    /// gives up (~24 s later) — and that late failure is then ignored.
    func test_a_dead_hls_origin_falls_back_to_mp3_and_its_late_failure_is_ignored() {
        var supervisor = Supervisor()
        let hls = start(&supervisor)
        playSteadily(&supervisor, attempt: hls, from: 0, to: 30)
        for time in stride(from: 31.0, through: 39, by: 1) {
            _ = supervisor.record(buffering(30), attempt: hls, at: time)
        }

        let mp3 = attempt(
            loadedBy: supervisor.record(buffering(30), attempt: hls, at: 40),
            stream: 1
        )

        XCTAssertEqual(supervisor.attemptFailed(hls, at: 55), .none)
        playSteadily(&supervisor, attempt: mp3, from: 41, to: 90,
                     playheadOffset: 41)
        XCTAssertEqual(supervisor.currentAttempt, mp3)
        XCTAssertEqual(supervisor.display, .playing)
    }

    // MARK: - Stale callbacks

    func test_callbacks_of_a_replaced_attempt_are_ignored() {
        var supervisor = Supervisor()
        let first = start(&supervisor)
        let second = attempt(
            loadedBy: supervisor.attemptFailed(first, at: 1), stream: 1
        )

        XCTAssertEqual(supervisor.record(playing(0), attempt: first, at: 2),
                       .none)
        XCTAssertEqual(supervisor.record(playing(5), attempt: first, at: 3),
                       .none)
        XCTAssertEqual(supervisor.attemptFailed(first, at: 4), .none)

        XCTAssertEqual(supervisor.display, .connecting)
        XCTAssertEqual(supervisor.currentAttempt, second)
        // The old attempt's progress did not start the new one: it still
        // times out 10 s after it was loaded, ending the round.
        XCTAssertEqual(supervisor.tick(at: 11),
                       .waitForRetry(delay: 2, report: true))
    }

    func test_callbacks_during_a_retry_wait_are_ignored() {
        var supervisor = Supervisor()
        let first = start(&supervisor)
        let second = attempt(
            loadedBy: supervisor.attemptFailed(first, at: 1), stream: 1
        )
        _ = supervisor.attemptFailed(second, at: 1)

        XCTAssertEqual(supervisor.attemptFailed(second, at: 1.5), .none)
        XCTAssertEqual(supervisor.record(playing(9), attempt: second, at: 2),
                       .none)
        XCTAssertEqual(supervisor.display, .retrying)
        XCTAssertNil(supervisor.currentAttempt)
    }

    // MARK: - Rounds and backoff

    func test_when_every_stream_fails_it_waits_then_starts_over_from_hls() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)

        let wait = failRound(&supervisor, startingWith: attempt, at: 2)

        XCTAssertEqual(wait, .waitForRetry(delay: 2, report: true))
        XCTAssertEqual(supervisor.display, .retrying)
        XCTAssertNil(supervisor.currentAttempt)
        XCTAssertTrue(supervisor.wantsAudio)
        XCTAssertEqual(supervisor.tick(at: 3.9), .none)
        _ = self.attempt(loadedBy: supervisor.tick(at: 4), stream: 0)
        XCTAssertEqual(supervisor.display, .connecting)
    }

    func test_backoff_grows_to_30s_and_the_failure_is_reported_once() {
        var supervisor = Supervisor()
        var attempt = start(&supervisor)
        var time: TimeInterval = 0
        var waits: [Supervisor.Action] = []

        for _ in 0..<6 {
            let wait = failRound(&supervisor, startingWith: attempt, at: time)
            waits.append(wait)
            guard case .waitForRetry(let delay, _) = wait else {
                return XCTFail("expected a wait, got \(wait)")
            }
            time += delay
            attempt = self.attempt(loadedBy: supervisor.tick(at: time),
                                   stream: 0)
        }

        XCTAssertEqual(waits, [
            .waitForRetry(delay: 2, report: true),
            .waitForRetry(delay: 4, report: false),
            .waitForRetry(delay: 8, report: false),
            .waitForRetry(delay: 16, report: false),
            .waitForRetry(delay: 30, report: false),
            .waitForRetry(delay: 30, report: false),
        ])
    }

    func test_a_station_with_one_stream_retries_that_stream() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor, streams: 1)

        XCTAssertEqual(supervisor.attemptFailed(attempt, at: 1),
                       .waitForRetry(delay: 2, report: true))
        _ = self.attempt(loadedBy: supervisor.tick(at: 3), stream: 0)
    }

    func test_thirty_seconds_of_playback_end_the_outage() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = failRound(&supervisor, startingWith: attempt, at: 1)
        let retry = self.attempt(loadedBy: supervisor.tick(at: 3), stream: 0)
        playSteadily(&supervisor, attempt: retry, from: 3, to: 33,
                     playheadOffset: 3)

        let wait = failRound(&supervisor, startingWith: retry, at: 34)

        // 2 s again, not 4: the stream that played ended the outage.
        XCTAssertEqual(wait, .waitForRetry(delay: 2, report: false))
    }

    func test_a_shorter_play_does_not_end_the_outage() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = failRound(&supervisor, startingWith: attempt, at: 1)
        let retry = self.attempt(loadedBy: supervisor.tick(at: 3), stream: 0)
        playSteadily(&supervisor, attempt: retry, from: 3, to: 31,
                     playheadOffset: 3)

        let wait = failRound(&supervisor, startingWith: retry, at: 32)

        // 28 s of audio: the backoff goes on growing.
        XCTAssertEqual(wait, .waitForRetry(delay: 4, report: false))
    }

    /// Review: the station's source stops. Its stale HLS playlist plays
    /// the same ~18 s on each rejoin and stalls, and Icecast's MP3 burst
    /// never starts. Those plays used to end the outage each time, so the
    /// listener heard one clip every ~20 s at the shortest backoff.
    func test_a_stream_that_plays_briefly_then_stalls_lets_the_backoff_grow() {
        var supervisor = Supervisor()
        var hls = start(&supervisor)
        var time: TimeInterval = 0
        var waits: [TimeInterval] = []

        for _ in 0..<4 {
            playSteadily(&supervisor, attempt: hls, from: time,
                         to: time + 18, playheadOffset: time)
            var action = Supervisor.Action.none
            var now = time + 19
            while action == .none {
                action = supervisor.record(buffering(18), attempt: hls, at: now)
                now += 1
            }
            XCTAssertEqual(supervisor.lastGiveUpReason, .stalled)
            let mp3 = attempt(loadedBy: action, stream: 1)
            guard case .waitForRetry(let delay, _) =
                    supervisor.attemptFailed(mp3, at: now) else {
                return XCTFail("expected a wait after the MP3 failed")
            }
            waits.append(delay)
            time = now + delay
            hls = attempt(loadedBy: supervisor.tick(at: time), stream: 0)
        }

        XCTAssertEqual(waits, [2, 4, 8, 16])
    }

    // MARK: - Stale HLS joins

    private func sample(
        _ status: Supervisor.PlaybackStatus,
        playhead: Double,
        liveLag: TimeInterval
    ) -> Supervisor.Sample {
        .init(status: status, playhead: playhead, liveLag: liveLag)
    }

    func test_an_hls_join_far_behind_live_is_abandoned_as_stale() {
        var supervisor = Supervisor()
        let hls = start(&supervisor)
        // Judged only once it plays: before that the playhead's date
        // says nothing.
        XCTAssertEqual(
            supervisor.record(sample(.buffering, playhead: 0, liveLag: 600),
                              attempt: hls, at: 0.5),
            .none
        )

        let next = supervisor.record(
            sample(.playing, playhead: 0, liveLag: 75), attempt: hls, at: 1
        )

        _ = attempt(loadedBy: next, stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .stale)
    }

    func test_an_hls_join_within_the_live_window_is_kept() {
        var supervisor = Supervisor()
        let hls = start(&supervisor)
        for time in stride(from: 1.0, through: 40, by: 1) {
            XCTAssertEqual(
                supervisor.record(
                    sample(.playing, playhead: time, liveLag: 60),
                    attempt: hls, at: time
                ),
                .none
            )
        }
        XCTAssertEqual(supervisor.currentAttempt, hls)
        XCTAssertNil(supervisor.lastGiveUpReason)
    }

    /// A stream that started stays, even once stalls it rode out put it
    /// further behind live than a join may be.
    func test_the_lag_of_a_started_stream_is_not_judged() {
        var supervisor = Supervisor()
        let hls = start(&supervisor)
        _ = supervisor.record(sample(.playing, playhead: 0, liveLag: 20),
                              attempt: hls, at: 0)
        _ = supervisor.record(sample(.playing, playhead: 1, liveLag: 20),
                              attempt: hls, at: 1)

        let action = supervisor.record(
            sample(.playing, playhead: 2, liveLag: 90), attempt: hls, at: 2
        )

        XCTAssertEqual(action, .none)
        XCTAssertEqual(supervisor.currentAttempt, hls)
    }

    /// A 2-minute start variant begins 120–132 s behind live on purpose:
    /// only lag beyond that offset tells a stale playlist.
    func test_a_join_behind_live_by_its_start_offset_is_kept() {
        var supervisor = Supervisor()
        let hls = attempt(
            loadedBy: supervisor.start(streamCount: 2, joinOffset: 120, at: 0),
            stream: 0
        )
        for time in stride(from: 1.0, through: 40, by: 1) {
            XCTAssertEqual(
                supervisor.record(
                    sample(.playing, playhead: time, liveLag: 175),
                    attempt: hls, at: time
                ),
                .none
            )
        }
        XCTAssertNil(supervisor.lastGiveUpReason)
    }

    func test_a_join_far_behind_its_start_offset_is_stale() {
        var supervisor = Supervisor()
        let hls = attempt(
            loadedBy: supervisor.start(streamCount: 2, joinOffset: 120, at: 0),
            stream: 0
        )

        let next = supervisor.record(
            sample(.playing, playhead: 0, liveLag: 185), attempt: hls, at: 1
        )

        _ = attempt(loadedBy: next, stream: 1)
        XCTAssertEqual(supervisor.lastGiveUpReason, .stale)
    }

    func test_stale_joins_count_as_failures_for_the_backoff() {
        var supervisor = Supervisor()
        var hls = start(&supervisor)
        var time: TimeInterval = 0
        var waits: [TimeInterval] = []

        for _ in 0..<3 {
            let mp3 = attempt(
                loadedBy: supervisor.record(
                    sample(.playing, playhead: 0, liveLag: 120),
                    attempt: hls, at: time + 1
                ),
                stream: 1
            )
            guard case .waitForRetry(let delay, _) =
                    supervisor.attemptFailed(mp3, at: time + 2) else {
                return XCTFail("expected a wait after the MP3 failed")
            }
            waits.append(delay)
            time += 2 + delay
            hls = attempt(loadedBy: supervisor.tick(at: time), stream: 0)
        }

        XCTAssertEqual(waits, [2, 4, 8])
    }

    func test_after_the_last_stream_played_and_failed_hls_is_tried_before_waiting() {
        var supervisor = Supervisor()
        let hls = start(&supervisor)
        let mp3 = attempt(
            loadedBy: supervisor.attemptFailed(hls, at: 0.1), stream: 1
        )
        playSteadily(&supervisor, attempt: mp3, from: 1, to: 600)

        let retryHls = attempt(
            loadedBy: supervisor.attemptFailed(mp3, at: 601), stream: 0
        )

        // Every stream had its try since the MP3 played: now it waits.
        XCTAssertEqual(supervisor.attemptFailed(retryHls, at: 602),
                       .waitForRetry(delay: 2, report: true))
    }

    // MARK: - Network

    func test_network_restore_during_a_wait_starts_a_round_at_once() {
        var supervisor = Supervisor()
        let first = start(&supervisor)
        _ = failRound(&supervisor, startingWith: first, at: 0)
        let second = attempt(loadedBy: supervisor.tick(at: 2), stream: 0)
        XCTAssertEqual(failRound(&supervisor, startingWith: second, at: 2),
                       .waitForRetry(delay: 4, report: false))

        let restored = supervisor.networkBecameAvailable(at: 3)

        _ = attempt(loadedBy: restored, stream: 0)
        // A fresh start: 10 s to connect (not 20), and the backoff starts
        // at 2 s again (not 8).
        let fallback = attempt(loadedBy: supervisor.tick(at: 13), stream: 1)
        XCTAssertEqual(supervisor.attemptFailed(fallback, at: 14),
                       .waitForRetry(delay: 2, report: false))
    }

    func test_network_restore_while_attempting_or_stopped_changes_nothing() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        XCTAssertEqual(supervisor.networkBecameAvailable(at: 1), .none)
        XCTAssertEqual(supervisor.currentAttempt, attempt)

        supervisor.stop()
        XCTAssertEqual(supervisor.networkBecameAvailable(at: 2), .none)
    }

    // MARK: - New streams

    func test_new_streams_are_taken_only_while_waiting_to_retry() {
        var supervisor = Supervisor()
        let first = start(&supervisor)
        XCTAssertFalse(supervisor.isWaitingToRetry)
        XCTAssertFalse(supervisor.replaceStreams(count: 3))

        _ = failRound(&supervisor, startingWith: first, at: 0)

        XCTAssertTrue(supervisor.isWaitingToRetry)
        XCTAssertFalse(supervisor.replaceStreams(count: 0))
        XCTAssertTrue(supervisor.replaceStreams(count: 3))
    }

    func test_the_next_round_walks_the_new_streams() {
        var supervisor = Supervisor()
        let first = start(&supervisor)
        _ = failRound(&supervisor, startingWith: first, at: 0)
        XCTAssertTrue(supervisor.replaceStreams(count: 3))

        let a = attempt(loadedBy: supervisor.tick(at: 2), stream: 0)
        let b = attempt(loadedBy: supervisor.attemptFailed(a, at: 2),
                        stream: 1)
        let c = attempt(loadedBy: supervisor.attemptFailed(b, at: 2),
                        stream: 2)

        XCTAssertEqual(supervisor.attemptFailed(c, at: 2),
                       .waitForRetry(delay: 4, report: false))
    }

    // MARK: - Stop

    func test_stop_cancels_everything_pending_for_an_attempt() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = supervisor.record(playing(0), attempt: attempt, at: 1)

        supervisor.stop()

        XCTAssertFalse(supervisor.wantsAudio)
        XCTAssertNil(supervisor.display)
        XCTAssertNil(supervisor.currentAttempt)
        XCTAssertEqual(supervisor.record(playing(5), attempt: attempt, at: 2),
                       .none)
        XCTAssertEqual(supervisor.attemptFailed(attempt, at: 3), .none)
        XCTAssertEqual(supervisor.tick(at: 1_000), .none)
        XCTAssertEqual(supervisor.networkBecameAvailable(at: 1_001), .none)
        XCTAssertNil(supervisor.display)
    }

    func test_stop_during_a_retry_wait_cancels_the_retry() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        _ = failRound(&supervisor, startingWith: attempt, at: 0)

        supervisor.stop()

        XCTAssertEqual(supervisor.tick(at: 100), .none)
        XCTAssertEqual(supervisor.networkBecameAvailable(at: 101), .none)
        XCTAssertFalse(supervisor.wantsAudio)
    }

    func test_a_new_play_request_reports_its_own_failure() {
        var supervisor = Supervisor()
        let attempt = start(&supervisor)
        XCTAssertEqual(failRound(&supervisor, startingWith: attempt, at: 0),
                       .waitForRetry(delay: 2, report: true))
        supervisor.stop()

        let next = self.attempt(
            loadedBy: supervisor.start(streamCount: 2, at: 10), stream: 0
        )

        XCTAssertNil(supervisor.lastGiveUpReason)
        XCTAssertEqual(failRound(&supervisor, startingWith: next, at: 10),
                       .waitForRetry(delay: 2, report: true))
    }

    // MARK: - AVPlayer mapping

    func test_avplayer_status_mapping() {
        typealias Status = Supervisor.PlaybackStatus
        XCTAssertEqual(
            Status(timeControlStatus: .playing, waitingReason: nil,
                   itemIsReady: true),
            .playing
        )
        XCTAssertEqual(
            Status(timeControlStatus: .playing, waitingReason: nil,
                   itemIsReady: false),
            .buffering
        )
        XCTAssertEqual(
            Status(timeControlStatus: .waitingToPlayAtSpecifiedRate,
                   waitingReason: .evaluatingBufferingRate, itemIsReady: true),
            .deciding
        )
        XCTAssertEqual(
            Status(timeControlStatus: .waitingToPlayAtSpecifiedRate,
                   waitingReason: .toMinimizeStalls, itemIsReady: true),
            .buffering
        )
        XCTAssertEqual(
            Status(timeControlStatus: .waitingToPlayAtSpecifiedRate,
                   waitingReason: .noItemToPlay, itemIsReady: false),
            .buffering
        )
        XCTAssertEqual(
            Status(timeControlStatus: .paused, waitingReason: nil,
                   itemIsReady: true),
            .paused
        )
    }
}
