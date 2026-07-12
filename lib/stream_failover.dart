/// Pure, unit-testable failover policy for a station's stream list.
///
/// A station exposes multiple streams (`station_streams[]`, HLS first,
/// then direct fallbacks). Historically `play()` always restarted its
/// retry cycle at index 0, so every reconnect triggered by a mid-playback
/// HLS death (stall timer, position watchdog, idle/completed) re-loaded
/// the same dead HLS URL forever — a stale-but-serving playlist passes
/// the load step, so the cycle never reached the healthy direct stream.
///
/// This class fixes that with three pieces:
///  1. Hard load timeouts ([loadTimeout]) so a hanging load counts as a
///     failure quickly instead of wedging the retry loop.
///  2. Per-URL failure memory ([recordFailure]/[startIndex]) so a retry
///     cycle starts at the first stream that has NOT failed recently.
///  3. Cycle backoff ([retryDelay]): instant advance between different
///     streams, increasing delay only once ALL streams failed a full
///     cycle — live radio never gives up, it just slows down.
class StreamFailover {
  /// Hard cap on a single HLS source load. HLS playlists are tiny; a load
  /// that hasn't finished in 3s is effectively down. Matches the value the
  /// retry loop has shipped with — it must not delay a healthy fast start.
  static const Duration hlsLoadTimeout = Duration(seconds: 3);

  /// Hard cap on a direct/MP3 source load. Was 10s — halved because 10s of
  /// silence before advancing to the next stream reads as "stuck" to the
  /// user, and a direct stream that can't produce its first bytes in 5s
  /// won't play smoothly anyway.
  static const Duration directLoadTimeout = Duration(seconds: 5);

  /// How long a URL failure is remembered. Chosen to outlive one full
  /// position-watchdog detection cycle (~22s worst case) plus a couple of
  /// stall-timer reconnects, so a repeatedly-freezing HLS stays skipped
  /// across consecutive recoveries — but expires soon enough that the
  /// preferred HLS stream is re-tried within a couple of minutes.
  static const Duration failureMemoryWindow = Duration(seconds: 90);

  /// Delay before the first attempt of retry cycles 1..3; cycles beyond
  /// that use [maxCycleBackoff]. Cycle 0 (first pass over all streams) is
  /// always instant.
  static const List<Duration> cycleBackoff = [
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  /// Backoff cap — keeps a total-outage retry loop cheap (one attempt per
  /// stream per ~10s) without ever giving up.
  static const Duration maxCycleBackoff = Duration(seconds: 10);

  final Map<String, DateTime> _lastFailureAt = {};

  /// Timeout to apply to a single source load.
  static Duration loadTimeout({required bool isHls}) =>
      isHls ? hlsLoadTimeout : directLoadTimeout;

  /// Delay to apply before attempt [retry] (0-based). Zero within a cycle
  /// (streams fail over to each other instantly); at each cycle boundary
  /// after the first full pass the delay grows: 1s, 2s, 5s, then 10s cap.
  static Duration retryDelay({required int retry, required int totalStreams}) {
    final cycleSize = totalStreams < 1 ? 1 : totalStreams;
    if (retry % cycleSize != 0) return Duration.zero;
    final cycle = retry ~/ cycleSize;
    if (cycle < cycleBackoff.length) return cycleBackoff[cycle];
    return maxCycleBackoff;
  }

  /// Marks [url] as failed at [now]. Callers: load failure/timeout in the
  /// retry loop, buffering-stall reconnect, idle/completed reconnect, and
  /// the position watchdog (a frozen stream is a failed stream even though
  /// its load "succeeded").
  void recordFailure(String url, DateTime now) {
    _lastFailureAt[url] = now;
  }

  /// Clears the failure memory for [url] — called on a successful load so
  /// a recovered HLS stream regains its preferred slot.
  void recordSuccess(String url) {
    _lastFailureAt.remove(url);
  }

  /// Whether [url] failed within [failureMemoryWindow] before [now].
  /// Expired entries are pruned as a side effect to keep the map bounded.
  bool isRecentlyFailed(String url, DateTime now) {
    final failedAt = _lastFailureAt[url];
    if (failedAt == null) return false;
    if (now.difference(failedAt) > failureMemoryWindow) {
      _lastFailureAt.remove(url);
      return false;
    }
    return true;
  }

  /// Index of the stream a new retry cycle should start from: the first
  /// URL (preferred order) with no recent failure. When every URL failed
  /// recently there is no better choice — start from the top so the
  /// preferred stream is still re-tried first.
  int startIndex(List<String> urls, DateTime now) {
    for (var i = 0; i < urls.length; i++) {
      if (!isRecentlyFailed(urls[i], now)) return i;
    }
    return 0;
  }
}
