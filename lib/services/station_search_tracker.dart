import 'dart:async';

import 'analytics_service.dart';

/// How many stations a search finds, by name and by the song on their row.
typedef StationSearchCounts = ({int byName, int bySong});

/// Records what listeners search for among the stations, as one
/// `station_searched` event per query they settle on.
///
/// The search runs on every keystroke, so a query is recorded only once
/// typing pauses for [settleDelay], or at once when the listener acts on
/// it (taps a result, ends the search), not "c", "cl", "clu" on the way
/// to "cluj". The same query isn't recorded twice in a row within one
/// search. `has_results: false` marks the searches that found nothing.
class StationSearchTracker {
  StationSearchTracker({
    required this.source,
    required this.countsFor,
    this.settleDelay = const Duration(milliseconds: 1500),
    void Function(String event, Map<String, Object?> properties)? capture,
  }) : _capture = capture ?? _captureInPostHog;

  static void _captureInPostHog(
          String event, Map<String, Object?> properties) =>
      AnalyticsService.instance.capture(event, properties);

  /// Where the search is: `mobile` or `desktop`.
  final String source;

  /// What the search finds for a query, read when it is recorded.
  final StationSearchCounts Function(String query) countsFor;

  final Duration settleDelay;

  final void Function(String event, Map<String, Object?> properties) _capture;

  Timer? _timer;
  String _pending = '';
  String? _lastRecorded;

  /// The listener typed [text]; recorded once it settles. Empty ends the
  /// search, recording what was typed before it.
  void queryChanged(String text) {
    final query = text.trim();
    if (query.isEmpty) {
      flush();
      _lastRecorded = null;
      return;
    }
    _pending = query;
    _timer?.cancel();
    _timer = Timer(settleDelay, flush);
  }

  /// Records the query still settling, if any, right away.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final query = _pending;
    _pending = '';
    if (query.isEmpty || _normalized(query) == _lastRecorded) return;
    _lastRecorded = _normalized(query);
    _capture('station_searched', _properties(query, countsFor(query)));
  }

  /// Records what is settling and stops; for when the search goes away.
  void dispose() => flush();

  Map<String, Object?> _properties(
    String query,
    StationSearchCounts counts,
  ) {
    final results = counts.byName + counts.bySong;
    return {
      'query': query,
      'query_normalized': _normalized(query),
      'results_count': results,
      'name_results_count': counts.byName,
      'song_results_count': counts.bySong,
      'has_results': results > 0,
      'source': source,
    };
  }

  static String _normalized(String query) =>
      query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}
