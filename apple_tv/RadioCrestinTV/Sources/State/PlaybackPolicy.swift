import Foundation

/// Pure playback-UX policies, kept free of AVFoundation and SwiftUI so the
/// decisions they encode are unit-testable without a player or a screen.
///
/// Three rules live here:
///  * `PlaylistEdgePolicy` — what a prev/next press means at the ends of a
///    playlist (hand off to the neighbouring *station* instead of wrapping).
///  * `PlaybackTimeoutPolicy` — how long a stream may sit "connecting"
///    before the UI must show a recoverable error.
///  * `ControlsAutoHidePolicy` — when the custom video overlay is allowed
///    to fade itself out.

// MARK: - Playlist edge navigation

/// Outcome of a manual prev/next press on a playlist station.
enum PlaylistNavigation: Equatable {
    /// Load this playlist index (still inside the current station).
    case item(Int)
    /// Past the last item — hand off to the next station in the list order.
    case nextStation
    /// Before the first item — hand off to the previous station.
    case previousStation
    /// Nothing to do (empty playlist).
    case none
}

/// Decides whether a manual prev/next press stays inside the playlist or
/// crosses over to the neighbouring station.
///
/// Manual navigation deliberately does **not** wrap: pressing next on the
/// last item advances to the next station (of any kind) and pressing
/// previous on the first item goes back a station. Auto-advance at an
/// item's natural end keeps its own looping behaviour and does not use
/// this policy.
enum PlaylistEdgePolicy {
    static func next(index: Int, count: Int) -> PlaylistNavigation {
        guard count > 0 else { return .none }
        guard index >= 0 else { return .item(0) }
        return index >= count - 1 ? .nextStation : .item(index + 1)
    }

    static func previous(index: Int, count: Int) -> PlaylistNavigation {
        guard count > 0 else { return .none }
        guard index < count else { return .item(count - 1) }
        return index <= 0 ? .previousStation : .item(index - 1)
    }
}

// MARK: - Connection timeout

/// Bounds how long the player may sit in `connecting` before the UI has to
/// show a recoverable error. Without it a stream whose server accepts the
/// socket but never sends media leaves AVPlayer waiting indefinitely and
/// the user staring at a spinner that never resolves.
enum PlaybackTimeoutPolicy {
    /// Wall-clock budget for a tune-in, measured from the moment the state
    /// becomes `connecting`. Covers the whole attempt including any
    /// sequential stream fallbacks — the bound is on the user's wait, not
    /// on an individual URL.
    static let connectTimeout: TimeInterval = 10

    /// User-facing copy for the timeout error (Romanian, matching the rest
    /// of the app's strings).
    static let timeoutMessage = "Fluxul nu a pornit în 10 secunde"

    /// True when a still-connecting attempt has outlived its budget.
    /// Extracted as a pure function so the rule can be tested without
    /// waiting ten real seconds.
    static func hasTimedOut(isConnecting: Bool, elapsed: TimeInterval) -> Bool {
        isConnecting && elapsed >= connectTimeout
    }
}

/// Playback failures the app raises itself (as opposed to the ones
/// AVFoundation hands back on `AVPlayerItem.error`). Reported to analytics
/// so a stream that silently never starts is distinguishable from one that
/// errored outright.
enum PlaybackError: Error, LocalizedError {
    case connectTimeout(seconds: TimeInterval)
    case stalled

    var errorDescription: String? {
        switch self {
        case .connectTimeout(let seconds):
            return "Stream did not start within \(Int(seconds))s"
        case .stalled:
            return "Playback clock stopped advancing"
        }
    }
}

// MARK: - Stall recovery

/// Detects and escalates recovery for a stream that has frozen mid-play.
///
/// `AVPlayer.timeControlStatus` cannot be trusted on its own here: a
/// frozen player can report `.playing` while its clock stands still
/// (measured on tvOS). Comparing successive `currentTime()` samples is
/// the only signal that reflects what the user actually experiences.
enum StallRecoveryPolicy {
    /// How often the watchdog samples the playback clock.
    static let sampleInterval: TimeInterval = 2

    /// Clock movement below this between samples counts as "frozen".
    static let minimumProgress: Double = 0.05

    /// How long the clock may stand still before we intervene. Long
    /// enough not to fight AVPlayer's own rebuffering, short enough that
    /// a user doesn't sit on a dead frame.
    static let stallGrace: TimeInterval = 6

    /// What to do on the Nth consecutive stall (1-based).
    enum Action: Equatable {
        case seekToLiveEdge
        case reloadItem
        case giveUp
    }

    static func isStalled(frozenFor: TimeInterval) -> Bool {
        frozenFor >= stallGrace
    }

    /// Escalates: cheap re-seek, then a full item reload, then hand back
    /// to the stream/item fallback chain.
    static func action(for attempt: Int) -> Action {
        switch attempt {
        case ..<1: return .seekToLiveEdge
        case 1: return .seekToLiveEdge
        case 2: return .reloadItem
        default: return .giveUp
        }
    }
}

// MARK: - Controls auto-hide

/// Governs the app-drawn video overlay (scrubber + transport buttons).
///
/// The app renders video into a bare `AVPlayerLayer` (see
/// `VideoSurfaceView`) rather than `AVPlayerViewController`, so tvOS draws
/// no system chrome and provides no system auto-hide — this policy is the
/// only thing that hides the controls.
enum ControlsAutoHidePolicy {
    /// Idle time before the overlay fades out during playback.
    static let idleTimeout: TimeInterval = 20

    /// True when the overlay may fade itself out. Controls stay pinned
    /// while paused (the user is looking at a frozen frame and needs the
    /// transport visible), while an error is on screen (its Retry button
    /// must remain reachable), and while playback is stalled — hiding the
    /// chrome over a frozen frame would misrepresent a stuck stream as a
    /// playing one.
    static func shouldAutoHide(
        isPlaying: Bool, hasError: Bool, isStalled: Bool = false
    ) -> Bool {
        isPlaying && !hasError && !isStalled
    }
}
