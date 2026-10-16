/// Turns a request that runs again and again into two log records: one when
/// it starts failing, one when it recovers, with how often and how long it
/// failed in between.
///
/// The station list syncs every minute, so logging each failed sync would
/// fill the log during a long outage and push out everything before it.
class FailureStreak {
  int _failures = 0;
  DateTime? _since;

  /// Records a failure at [now]. True for the first failure of a streak,
  /// the one worth logging.
  bool fail(DateTime now) {
    _failures++;
    if (_failures > 1) return false;
    _since = now;
    return true;
  }

  /// Records a success at [now]. Returns the streak it ends, or null when
  /// nothing was failing.
  ({int failures, Duration duration})? succeed(DateTime now) {
    final since = _since;
    if (_failures == 0 || since == null) return null;
    final ended = (failures: _failures, duration: now.difference(since));
    _failures = 0;
    _since = null;
    return ended;
  }
}
