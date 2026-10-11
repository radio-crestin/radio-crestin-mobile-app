/// Pure policy deciding whether the 60 s station-list sync keeps running
/// while the app is in the background.
///
/// Extracted from `HomePage.didChangeAppLifecycleState` so the rule is
/// unit-testable without a widget tree.
abstract final class BackgroundPollingPolicy {
  /// True when nobody looks at the station list, so the periodic sync should
  /// pause: no car or Cast screen shows its metadata, and the listener is on
  /// mobile data (save data) or not playing locally.
  ///
  /// [playing] is the local player's state; while casting it is false
  /// because the audio plays on the receiver, hence the [casting] check.
  /// The playing station's time-shifted song does not depend on this sync:
  /// it follows the playlist's song boundaries.
  static bool shouldPause({
    required bool carConnected,
    required bool casting,
    required bool onMobileData,
    required bool playing,
  }) =>
      !carConnected && !casting && (onMobileData || !playing);
}
