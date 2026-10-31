import AVFoundation

/// Decides when a live stream has stopped serving the listener and the
/// engine must move on: to the station's next stream or, once every stream
/// failed, to a new round after a pause.
///
/// AVPlayer alone gives up too late or never (tvOS 27, 2026-10-30): when
/// an HLS origin goes away mid-play, the item stays `readyToPlay` while
/// AVPlayer retries the playlist for ~24 s and then simply pauses; when a
/// segment hangs, it waits forever. Neither sets `status == .failed`, so a
/// fallback that only listens for `.failed` leaves the listener in silence
/// while the UI says it is playing.
///
/// The rules:
/// * an attempt counts as started only once AVPlayer is playing **and** the
///   playhead advances;
/// * an attempt that has not started within the connect timeout, or that
///   started and then stood still for the stall timeout, is abandoned, as
///   is one AVPlayer reports as failed or ended, and an HLS join whose
///   audio is far older than live (a playlist that stopped advancing);
/// * an outage ends only once a stream has played for a while
///   (`Timing.recoveryPlayback`), not at its first second: a source that
///   stopped still yields a few seconds of old audio per reconnect, and
///   counting those as recoveries kept the backoff at its shortest;
/// * after a stream ended an outage, every other stream gets one try
///   (wrapping to the first) before the engine waits; when all of them
///   failed, it waits per `RetryBackoff` and starts again from the first
///   stream (HLS), or at once when the network comes back.
///
/// A pure value type: it is fed the time (seconds on a monotonic clock),
/// what AVPlayer reports and the playhead, and returns what to do. The
/// engine owns AVPlayer and the timers; every rule here is unit-tested
/// without them.
struct LiveStreamSupervisor {
    /// What AVPlayer is doing, reduced to what the supervisor decides on.
    enum PlaybackStatus: Equatable {
        /// `timeControlStatus == .playing` on a ready item.
        case playing
        /// AVPlayer wants to play but has no media data: a stall, or an item
        /// that is still loading.
        case buffering
        /// The brief `evaluatingBufferingRate` wait while AVPlayer decides
        /// whether it has enough buffer. Apple recommends not presenting it
        /// as buffering, so it changes neither the display nor the progress.
        case deciding
        /// Rate 0: AVPlayer is not trying to play.
        case paused
    }

    /// One look at the player.
    struct Sample: Equatable {
        var status: PlaybackStatus
        /// Playhead in seconds; nil while AVPlayer has no valid time.
        var playhead: Double?
        /// How far the audio at the playhead is behind the wall clock, in
        /// seconds, from its HLS `EXT-X-PROGRAM-DATE-TIME`; nil for streams
        /// without one (MP3/AAC) and before the item is ready.
        var liveLag: TimeInterval?
    }

    /// What the engine must do next.
    enum Action: Equatable {
        case none
        /// Drop the current item and load `stream` (an index into the
        /// station's streams), tagged `attempt` so its callbacks can be told
        /// apart from those of items it replaced.
        case load(stream: Int, attempt: Int)
        /// Every stream failed: drop the item and wait `delay` seconds for
        /// the next round. `report` is true for the first such wait of a
        /// play request only, so the failure reaches analytics once rather
        /// than once per round.
        case waitForRetry(delay: TimeInterval, report: Bool)
    }

    /// What the listener should see while they want audio.
    enum Display: Equatable {
        case connecting
        case playing
        /// Waiting before a new round; still "connecting" to the listener.
        case retrying
    }

    /// Why the supervisor abandoned the last attempt.
    enum GiveUpReason: Equatable {
        /// AVPlayer reported the item failed, broke off, or ended.
        case failed
        /// It did not start within the connect timeout.
        case noStart
        /// It started, then the playhead stood still for the stall timeout.
        case stalled
        /// An HLS join whose audio was older than `Timing.maxJoinLag`: the
        /// playlist stopped advancing because the station's source stopped.
        case stale
    }

    /// Thresholds, injectable so tests state them explicitly.
    struct Timing: Equatable {
        /// Time a stream gets to start. Joins measure 0.5 s (HLS) to 0.8 s
        /// (MP3), while an HLS origin that never answers kept the listener
        /// waiting for AVPlayer's own 20 s before the MP3 fallback. Ten
        /// seconds is over ten times a normal join, so a slow but working
        /// stream is kept, and halves that wait.
        var connectTimeout: TimeInterval = 10

        /// Time a stream gets to start once a whole round has failed: the
        /// same 20 s AVPlayer allows a connection. By then a quick fallback
        /// matters less than letting a slow link get through at all.
        var retryConnectTimeout: TimeInterval = 20

        /// Time a started stream may stand still. With the live forward
        /// buffer, a stall means the buffer already ran dry. AVPlayer often
        /// refetches within a few seconds, but it retried a dead HLS origin
        /// for ~24 s before giving up, and never gave up on a hung segment.
        /// Ten seconds rides out a refetch, then falls back to the next
        /// stream (MP3) instead of leaving the listener in silence.
        var stallTimeout: TimeInterval = 10

        /// How far the playhead must move between two looks to count as
        /// playing: far below the ~1 s that passes between two looks while
        /// audio plays, and above any rounding of a playhead that is frozen.
        var minimumProgress: TimeInterval = 0.1

        /// Audio a stream must play before the outage counts as over: the
        /// backoff starts again from its shortest wait and every other
        /// stream gets a fresh try. A station whose source stopped still
        /// plays a little on each reconnect: a stale HLS playlist plays out
        /// the ≤ 24 s between its join (18 s before its end, aligned to a
        /// 6 s segment) and its end, and Icecast replays a burst of a few
        /// seconds. Thirty seconds is more than either, so only a stream
        /// that delivers new audio ends the outage.
        var recoveryPlayback: TimeInterval = 30

        /// How far behind the wall clock an HLS join's audio may be, beyond
        /// the offset it was asked to start at (`start`'s `joinOffset`). A
        /// live join is 18–30 s behind: 18 s before the playlist's end,
        /// which trails real time by up to one 6 s segment and its
        /// publication; a 2- or 5-minute start variant adds its offset to
        /// that. A playlist whose source stopped no longer advances, so
        /// each rejoin lands further back and replays audio the listener
        /// already heard. Twice the live lag tells the two apart with room
        /// for a slow packager; a working stream is never that far behind.
        var maxJoinLag: TimeInterval = 60

        var backoff = RetryBackoff()
    }

    private struct Attempt: Equatable {
        let id: Int
        let stream: Int
        let loadedAt: TimeInterval
        let connectTimeout: TimeInterval
        var hasStarted = false
        /// Seconds of audio it played: playhead progress between looks
        /// that both found AVPlayer playing.
        var played: TimeInterval = 0
        var lastProgressAt: TimeInterval
        /// Playhead at the last look that found AVPlayer playing; nil after
        /// one that did not. Progress is measured only between two playing
        /// looks, so a jump while loading (an HLS join placing the playhead
        /// 18 s behind the live edge) never counts as audio heard.
        var playheadWhilePlaying: Double?
    }

    private enum Phase: Equatable {
        case stopped
        case attempting(Attempt)
        case waitingToRetry(until: TimeInterval)
    }

    let timing: Timing

    /// What the listener should see; nil while they do not want audio.
    private(set) var display: Display?

    /// Why the last attempt was abandoned; nil until one is.
    private(set) var lastGiveUpReason: GiveUpReason?

    private var phase: Phase = .stopped
    private var streamCount = 0
    /// How far behind live the play request asked HLS to start.
    private var joinOffset: TimeInterval = 0
    /// Streams still to try before the current round counts as failed.
    private var remainingInRound = 0
    /// Rounds failed in a row since a stream last ended an outage or the
    /// network came back; drives the backoff and the connect timeout.
    private var failedRounds = 0
    /// Never reset, so attempt ids stay unique across play requests and a
    /// callback from an earlier request can never match a later attempt.
    private var nextAttemptID = 1
    private var hasReportedFailure = false

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// True from `start` until `stop`: the listener wants audio.
    var wantsAudio: Bool { phase != .stopped }

    /// The attempt whose item should be loaded; nil while waiting to retry
    /// or stopped.
    var currentAttempt: Int? {
        if case .attempting(let attempt) = phase { return attempt.id }
        return nil
    }

    /// True between two rounds, when no stream is loaded.
    var isWaitingToRetry: Bool {
        if case .waitingToRetry = phase { return true }
        return false
    }

    // MARK: - Inputs

    /// A new play request: forgets everything about the previous one and
    /// loads the first stream. `joinOffset`: how far behind live its HLS
    /// streams start on purpose (a start variant), which is not staleness.
    mutating func start(
        streamCount: Int,
        joinOffset: TimeInterval = 0,
        at now: TimeInterval
    ) -> Action {
        stop()
        guard streamCount > 0 else { return .none }
        self.streamCount = streamCount
        self.joinOffset = joinOffset
        failedRounds = 0
        hasReportedFailure = false
        lastGiveUpReason = nil
        return beginRound(at: now)
    }

    /// The listener paused, stopped or left: nothing is pending any more,
    /// and every later input is ignored until the next `start`.
    mutating func stop() {
        phase = .stopped
        display = nil
    }

    /// A look at the player while `attempt` is loaded (KVO change or the
    /// periodic tick). Samples for any other attempt are ignored.
    mutating func record(
        _ sample: Sample, attempt id: Int, at now: TimeInterval
    ) -> Action {
        guard case .attempting(var attempt) = phase, attempt.id == id else {
            return .none
        }
        switch sample.status {
        case .playing:
            // Checked as the join starts to play, once AVPlayer has placed
            // the playhead: before that its date says nothing.
            if !attempt.hasStarted, let lag = sample.liveLag,
               lag > timing.maxJoinLag + joinOffset {
                return giveUp(.stale, at: now)
            }
            display = .playing
            trackProgress(of: &attempt, playhead: sample.playhead, at: now)
        case .buffering, .paused:
            display = .connecting
            attempt.playheadWhilePlaying = nil
        case .deciding:
            break
        }
        phase = .attempting(attempt)
        return checkDeadlines(at: now)
    }

    /// Time passed with no new sample (the periodic tick while no item is
    /// loaded, i.e. during a retry wait).
    mutating func tick(at now: TimeInterval) -> Action {
        checkDeadlines(at: now)
    }

    /// AVPlayer reported that `attempt` failed, broke off before its end,
    /// or ended — all of which mean no more audio from it.
    mutating func attemptFailed(_ id: Int, at now: TimeInterval) -> Action {
        guard currentAttempt == id else { return .none }
        return giveUp(.failed, at: now)
    }

    /// The network path became usable again. During a retry wait the next
    /// round starts now, with a fresh backoff: the failures were most
    /// likely the outage, not the station.
    mutating func networkBecameAvailable(at now: TimeInterval) -> Action {
        guard case .waitingToRetry = phase else { return .none }
        failedRounds = 0
        return beginRound(at: now)
    }

    /// The station now has `count` streams (the catalog changed its URLs).
    /// Accepted only while waiting to retry, when no stream index is in
    /// use; the next round walks the new streams. Returns whether the
    /// engine may switch to them.
    mutating func replaceStreams(count: Int) -> Bool {
        guard isWaitingToRetry, count > 0 else { return false }
        streamCount = count
        return true
    }

    // MARK: - Rules

    private mutating func trackProgress(
        of attempt: inout Attempt, playhead: Double?, at now: TimeInterval
    ) {
        guard let playhead else { return }
        guard let previous = attempt.playheadWhilePlaying else {
            attempt.playheadWhilePlaying = playhead
            return
        }
        if playhead > previous + timing.minimumProgress {
            let playedBefore = attempt.played
            attempt.played += playhead - previous
            if playedBefore < timing.recoveryPlayback,
               attempt.played >= timing.recoveryPlayback {
                // The stream delivers new audio: the outage, if any, is
                // over. Every other stream gets a fresh try if this one
                // fails later.
                failedRounds = 0
                remainingInRound = streamCount - 1
            }
            attempt.hasStarted = true
            attempt.lastProgressAt = now
            attempt.playheadWhilePlaying = playhead
        } else if playhead < previous {
            // AVPlayer moved the playhead back (a live rejoin): measure
            // further progress from there.
            attempt.playheadWhilePlaying = playhead
        }
    }

    private mutating func checkDeadlines(at now: TimeInterval) -> Action {
        switch phase {
        case .stopped:
            return .none
        case .waitingToRetry(let until):
            return now >= until ? beginRound(at: now) : .none
        case .attempting(let attempt):
            if attempt.hasStarted {
                let stillFor = now - attempt.lastProgressAt
                return stillFor >= timing.stallTimeout
                    ? giveUp(.stalled, at: now) : .none
            }
            return now - attempt.loadedAt >= attempt.connectTimeout
                ? giveUp(.noStart, at: now) : .none
        }
    }

    private mutating func giveUp(
        _ reason: GiveUpReason, at now: TimeInterval
    ) -> Action {
        guard case .attempting(let attempt) = phase else { return .none }
        lastGiveUpReason = reason
        if remainingInRound > 0 {
            remainingInRound -= 1
            return load(stream: (attempt.stream + 1) % streamCount, at: now)
        }
        failedRounds += 1
        let delay = timing.backoff.delay(afterFailedRounds: failedRounds)
        phase = .waitingToRetry(until: now + delay)
        display = .retrying
        let report = !hasReportedFailure
        hasReportedFailure = true
        return .waitForRetry(delay: delay, report: report)
    }

    private mutating func beginRound(at now: TimeInterval) -> Action {
        remainingInRound = streamCount - 1
        return load(stream: 0, at: now)
    }

    private mutating func load(stream: Int, at now: TimeInterval) -> Action {
        let id = nextAttemptID
        nextAttemptID += 1
        phase = .attempting(Attempt(
            id: id,
            stream: stream,
            loadedAt: now,
            connectTimeout: failedRounds == 0
                ? timing.connectTimeout : timing.retryConnectTimeout,
            lastProgressAt: now
        ))
        display = .connecting
        return .load(stream: stream, attempt: id)
    }
}

// MARK: - AVPlayer mapping

extension LiveStreamSupervisor.PlaybackStatus {
    /// Reduces what AVPlayer reports to a supervisor status.
    ///
    /// AVPlayer cannot be playing an item that is not `readyToPlay`; such a
    /// reading is the previous item's status not yet updated after
    /// `replaceCurrentItem`, so it counts as buffering. Waiting reasons
    /// other than `evaluatingBufferingRate` (stalls, no item, anything
    /// future) all mean no audio is coming.
    init(
        timeControlStatus: AVPlayer.TimeControlStatus,
        waitingReason: AVPlayer.WaitingReason?,
        itemIsReady: Bool
    ) {
        switch timeControlStatus {
        case .playing:
            self = itemIsReady ? .playing : .buffering
        case .waitingToPlayAtSpecifiedRate:
            self = waitingReason == .evaluatingBufferingRate
                ? .deciding : .buffering
        case .paused:
            self = .paused
        @unknown default:
            self = .buffering
        }
    }
}
