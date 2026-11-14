/// A one-time "don't start the radio" for the next return to the app.
///
/// On iOS, coming back to the app starts the last station when "Pornește
/// automat ultima stație" is on. When the listener left on purpose for
/// something else to hear (a YouTube video from an announcement), that
/// return must not start the radio again.
class AutoplayHold {
  AutoplayHold._();

  static bool _held = false;

  /// Holds the next return's autoplay.
  static void holdNextResume() => _held = true;

  /// Drops the hold (nothing left the app after all).
  static void release() => _held = false;

  /// Whether this return is held; the hold is used up either way.
  static bool consume() {
    final held = _held;
    _held = false;
    return held;
  }
}
