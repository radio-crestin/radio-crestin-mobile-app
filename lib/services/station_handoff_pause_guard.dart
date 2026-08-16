/// Suppresses the ONE stray platform pause that can arrive while the app hands
/// playback from a YouTube playlist item over to the next station.
///
/// ## Why this exists
///
/// A `youtube` playlist item is not played by our engine — it runs inside a
/// `WKWebView` that owns the system's Now Playing / remote-command role while
/// its media session is active. Advancing to the next station tears that
/// webview down. iOS reacts to the abrupt release by delivering a
/// `MPRemoteCommandCenter` **pause** to our command center — which by then is
/// already wired to the freshly started station stream. Device telemetry caught
/// it landing 0.5–3.4s after the switch: the new stream loaded fine and was
/// then paused half a second later, so the user saw a station change that never
/// played (the reported "Postul următor doesn't start playing" bug).
///
/// The pause is genuine platform input, indistinguishable by state, so it is
/// filtered by ORIGIN + TIME instead: the handoff arms a short window, and the
/// first platform pause inside it is dropped. A pause the USER asked for
/// (transport / mini player / lock screen tap routed through
/// `AppAudioHandler.pauseFromUser`) always disarms the guard first, so it is
/// never swallowed.
///
/// Deliberately a tiny, pure, injectable-clock class so all of the timing
/// behavior is unit-testable without an audio stack.
class StationHandoffPauseGuard {
  StationHandoffPauseGuard({this.window = const Duration(seconds: 5)});

  /// How long after the handoff a stray pause is still attributed to it.
  /// Comfortably past the worst observed delay (3.4s) and short enough that a
  /// later, genuine platform pause is never affected.
  final Duration window;

  DateTime? _until;

  /// Whether a stray pause would currently be dropped.
  bool get isArmed => _until != null;

  /// Arms the guard for [window] starting at [now]. Called when a station
  /// advance leaves a YouTube playlist item behind.
  void arm(DateTime now) => _until = now.add(window);

  /// Clears the guard — used the moment a user-initiated pause arrives, so the
  /// user's intent always wins over the suppression window.
  void disarm() => _until = null;

  /// Whether the platform pause arriving at [now] is the stray handoff one.
  ///
  /// ONE-SHOT: the first pause inside the window is consumed and the guard
  /// disarms, so a second pause (the user tapping pause right after the switch)
  /// goes through. Also disarms when the window has simply elapsed.
  bool shouldIgnorePause(DateTime now) {
    final until = _until;
    if (until == null) return false;
    _until = null;
    return now.isBefore(until);
  }
}
