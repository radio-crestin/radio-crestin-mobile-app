import 'dart:io' show HttpDate, HttpException;

import 'package:radio_crestin/services/hls_timeline.dart' show SongBoundaryHint;

/// One now-playing row: the wall-clock instant the song started plus the API
/// `now_playing` JSON (`timestamp`, `listeners`, `song`).
///
/// Shared by the live list (`/stations-metadata`), the history endpoint and
/// the B14 playlist hint, so every source is compared on the same terms.
class NowPlayingRow {
  const NowPlayingRow({required this.startedAt, required this.nowPlaying});

  /// When the song started, in UTC.
  final DateTime startedAt;

  /// API-shaped `now_playing` map.
  final Map<String, dynamic> nowPlaying;

  /// The song's id, or null for a row without a song (source silent).
  int? get songId {
    final song = nowPlaying['song'];
    return song is Map<String, dynamic> ? song['id'] as int? : null;
  }

  /// Null when [json] has no parseable `timestamp`.
  static NowPlayingRow? fromNowPlayingJson(Map<String, dynamic>? json) {
    final timestamp = json?['timestamp'];
    if (timestamp is! String) return null;
    final startedAt = DateTime.tryParse(timestamp);
    if (startedAt == null) return null;
    return NowPlayingRow(startedAt: startedAt.toUtc(), nowPlaying: json!);
  }

  @override
  String toString() =>
      'NowPlayingRow(${startedAt.toIso8601String()}, song $songId)';
}

/// `from_timestamp` / `to_timestamp` of a history query, in Unix seconds.
class HistoryWindow {
  const HistoryWindow(this.from, this.to);

  final int from;
  final int to;

  @override
  bool operator ==(Object other) =>
      other is HistoryWindow && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'HistoryWindow($from, $to)';
}

/// One history response: its rows in API order, plus when the origin
/// generated it (null when the headers do not say).
class HistoryPage {
  const HistoryPage(this.rows, this.generatedAt);

  final List<NowPlayingRow> rows;
  final DateTime? generatedAt;
}

/// Pure rules for picking the song a listener hears on time-shifted HLS.
///
/// Every instant is server wall clock: a song boundary `B` (playlist EPOCH or
/// DATERANGE START-DATE), the audible instant `A`, and the row timestamps.
abstract final class AudibleSongPolicy {
  /// EPOCH is `int(started_at)`, so the change row sits in [E, E+1); the rest
  /// is slack for DATERANGE millisecond starts.
  static const changeRowLead = Duration(milliseconds: 1500);

  /// Rows stamped after the boundary they belong to (radio-eldad +10.6 s,
  /// rows dated at ingestion).
  static const changeRowLag = Duration(seconds: 20);

  /// After this, every row at or before an instant has been ingested
  /// (measured maximum ingestion lag: 37.7 s).
  static const ingestionSafety = Duration(seconds: 60);

  /// How far back an anchor looks; a longer-running item falls back to the
  /// live row.
  static const anchorLookback = Duration(hours: 1);

  /// Gaps between attempts while a row is not ingested yet (55 s in total,
  /// which covers [ingestionSafety] from the first attempt on).
  static const retryDelays = [
    Duration(seconds: 3),
    Duration(seconds: 7),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// `to_timestamp` stays this far behind the device clock: the API rejects
  /// `to > now + 2`, so device clocks up to 4 s fast still work.
  static const clockGuard = Duration(seconds: 2);

  /// The row that starts the song heard from [boundary] on, or null when the
  /// response does not contain it yet (not ingested, or a stale cached copy).
  ///
  /// Takes the earliest row starting in [B − lead, B + lag]: a later one (a
  /// jingle at B+8) would show the next item early. Rows of [songBefore], the
  /// song audible before the boundary, are skipped: they are that song still
  /// running (a listener-count row dated after B, or a window-local history
  /// dedupe), not the change. On equal starts (backend tie, B3) the last of
  /// them in API order wins.
  static NowPlayingRow? changeRow(
    List<NowPlayingRow> rows,
    DateTime boundary, {
    int? songBefore,
  }) {
    final earliest = boundary.subtract(changeRowLead);
    final latest = boundary.add(changeRowLag);
    NowPlayingRow? best;
    for (final row in rows) {
      if (row.startedAt.isBefore(earliest) || row.startedAt.isAfter(latest)) {
        continue;
      }
      if (songBefore != null && row.songId == songBefore) continue;
      if (best == null || !row.startedAt.isAfter(best.startedAt)) best = row;
    }
    return best;
  }

  /// Whether one row (the live one) is exactly the change row of [boundary].
  static bool isExactChangeRow(NowPlayingRow row, DateTime boundary) =>
      row.startedAt.difference(boundary).abs() <= changeRowLead;

  /// The newest row starting at or before [audible]; ties: the last in API
  /// order.
  static NowPlayingRow? rowAt(List<NowPlayingRow> rows, DateTime audible) {
    NowPlayingRow? best;
    for (final row in rows) {
      if (row.startedAt.isAfter(audible)) continue;
      if (best == null || !row.startedAt.isBefore(best.startedAt)) best = row;
    }
    return best;
  }

  /// Whether the live list proves that [live] is what is audible at
  /// [audible]: it started by then, and the list was fetched long enough
  /// after [audible] ([liveCursor], Unix seconds) to hold every later row.
  static bool liveProvesAudible({
    required NowPlayingRow live,
    required DateTime audible,
    required int liveCursor,
  }) =>
      !live.startedAt.isAfter(audible) &&
      liveCursor - _epochSeconds(audible) >= ingestionSafety.inSeconds;

  /// Whether a response generated at [generatedAt] already holds every row
  /// that starts by [instant] plus the change-row lag, so an absent row does
  /// not exist. Unknown generation time is never settled.
  static bool isSettled(DateTime? generatedAt, DateTime instant) =>
      generatedAt != null &&
      !generatedAt.isBefore(instant.add(ingestionSafety));

  /// When the origin generated a response, from its headers.
  ///
  /// `Last-Modified` is the generation time (backend contract C-4). Without
  /// it, `Date − Age` is the same instant for a copy a cache kept; a `Date`
  /// alone may be a cache's serve time, so it is not trusted.
  static DateTime? generationTime(Map<String, String> headers) {
    final lastModified = _httpDate(headers['last-modified']);
    if (lastModified != null) return lastModified;
    final date = _httpDate(headers['date']);
    final age = int.tryParse(headers['age']?.trim() ?? '');
    if (date == null || age == null) return null;
    return date.subtract(Duration(seconds: age));
  }

  /// `[b − 2, min(b + 20 + attempt, now − 2)]`, b = floor(B): the same key
  /// for every listener of a change, and a new one per attempt so a retry
  /// never meets the cached copy that lacked the row.
  static HistoryWindow changeWindow({
    required DateTime boundary,
    required int attempt,
    required int nowEpoch,
  }) {
    final b = _epochSeconds(boundary);
    final from = b - 2;
    final to = _min(
        b + changeRowLag.inSeconds + attempt, nowEpoch - clockGuard.inSeconds);
    return HistoryWindow(from, to < from ? from : to);
  }

  /// `[to − 3600, to]`, to = min(ceil10(A), now − 2): shared by every
  /// listener whose audible instant falls in the same 10 s bucket.
  static HistoryWindow anchorWindow({
    required DateTime audible,
    required int nowEpoch,
  }) {
    final ceil10 = (audible.millisecondsSinceEpoch + 9999) ~/ 10000 * 10;
    final to = _min(ceil10, nowEpoch - clockGuard.inSeconds);
    return HistoryWindow(to - anchorLookback.inSeconds, to);
  }

  /// API-shaped `now_playing` for a complete B14 hint (song id and a
  /// non-blank title), else null: a title-only hint is raw stream text that
  /// may disagree with the API's row.
  static Map<String, dynamic>? nowPlayingFromHint(
    SongBoundaryHint? hint,
    DateTime boundary,
  ) {
    final songId = hint?.songId;
    final title = hint?.title?.trim() ?? '';
    if (hint == null || songId == null || title.isEmpty) return null;
    final artist = hint.artist?.trim() ?? '';
    return {
      'timestamp': boundary.toUtc().toIso8601String(),
      'song': {
        'id': songId,
        'name': title,
        'thumbnail_url': hint.thumbnailUrl,
        'artist': artist.isEmpty
            ? null
            : {'id': hint.artistId ?? 0, 'name': artist, 'thumbnail_url': null},
      },
    };
  }

  static int _epochSeconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  static int _min(int a, int b) => a < b ? a : b;

  static DateTime? _httpDate(String? value) {
    if (value == null) return null;
    try {
      return HttpDate.parse(value);
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }
}
