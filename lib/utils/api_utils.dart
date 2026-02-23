/// Returns a Unix timestamp (seconds) rounded to the nearest 10 seconds,
/// optionally shifted back by [offset].
int getRoundedTimestamp({Duration offset = Duration.zero}) {
  final now = DateTime.now().subtract(offset);
  final epochSeconds = now.millisecondsSinceEpoch ~/ 1000;
  return (epochSeconds ~/ 10) * 10;
}

/// Appends a `timestamp=<rounded_timestamp>` query parameter to [url].
String addTimestampToUrl(String url, {Duration offset = Duration.zero}) {
  final timestamp = getRoundedTimestamp(offset: offset);
  final uri = Uri.parse(url);
  final queryParams = Map<String, String>.from(uri.queryParameters);
  queryParams['timestamp'] = timestamp.toString();
  return uri.replace(queryParameters: queryParams).toString();
}
