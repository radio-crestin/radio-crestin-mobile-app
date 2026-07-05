/// Returns a Unix timestamp (seconds) rounded to the nearest 10 seconds,
/// optionally shifted back by [offset].
int getRoundedTimestamp({Duration offset = Duration.zero}) {
  final now = DateTime.now().subtract(offset);
  final epochSeconds = now.millisecondsSinceEpoch ~/ 1000;
  return (epochSeconds ~/ 10) * 10;
}

/// Returns a Unix timestamp (seconds) floored to the nearest 5 seconds,
/// optionally shifted back by [offset].
///
/// The `/station-playlist` endpoint caches on a 5s key (finer than the 10s
/// `/stations-metadata` cadence) so the live playlist reflects changes within
/// a single poll. Floors (never rounds up) so the timestamp never runs ahead
/// of wall-clock, which the backend would treat as a cache miss.
int getRoundedTimestamp5s({Duration offset = Duration.zero}) {
  final now = DateTime.now().subtract(offset);
  final epochSeconds = now.millisecondsSinceEpoch ~/ 1000;
  return (epochSeconds ~/ 5) * 5;
}

/// Appends a `timestamp=<rounded_timestamp>` query parameter to [url].
String addTimestampToUrl(String url, {Duration offset = Duration.zero}) {
  final timestamp = getRoundedTimestamp(offset: offset);
  final uri = Uri.parse(url);
  final queryParams = Map<String, String>.from(uri.queryParameters);
  queryParams['timestamp'] = timestamp.toString();
  return uri.replace(queryParameters: queryParams).toString();
}
