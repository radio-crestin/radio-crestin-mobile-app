/// Keeps the play loop's retries, which never give up, from flooding the
/// log.
///
/// The first passes over a station's streams are logged attempt by attempt.
/// Past them, failures are only counted and summed up every [summaryEvery].
/// An outage of hours then costs a few records an hour instead of
/// thousands, and the history before it stays in the log file.
class RetryLogThrottle {
  RetryLogThrottle({
    this.detailedPasses = 2,
    this.summaryEvery = const Duration(minutes: 5),
  });

  /// Passes over the streams that are logged attempt by attempt.
  final int detailedPasses;

  /// How often the counted failures are summed up.
  final Duration summaryEvery;

  int _quietFailures = 0;
  DateTime? _lastSummaryAt;

  /// Whether attempt [retry] is logged in full, with [totalStreams] streams
  /// per pass.
  bool isDetailed({required int retry, required int totalStreams}) =>
      retry < detailedPasses * (totalStreams < 1 ? 1 : totalStreams);

  /// Counts a failure that is not logged in full. Returns how many failures
  /// the summary due now covers: at the first one, then once every
  /// [summaryEvery]. Null while no summary is due.
  int? quietFailure(DateTime now) {
    _quietFailures++;
    final last = _lastSummaryAt;
    if (last != null && now.difference(last) < summaryEvery) return null;
    final failures = _quietFailures;
    _quietFailures = 0;
    _lastSummaryAt = now;
    return failures;
  }
}
