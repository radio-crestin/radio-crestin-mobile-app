import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/services/audible_song_policy.dart';
import 'package:radio_crestin/services/now_playing_sanitizer.dart';

/// A single item in the song history timeline.
class SongHistoryItem {
  final String timestamp;
  final int? listeners;
  final int? songId;
  final String? songName;
  final String? songThumbnailUrl;
  final int? artistId;
  final String? artistName;
  final String? artistThumbnailUrl;

  const SongHistoryItem({
    required this.timestamp,
    this.listeners,
    this.songId,
    this.songName,
    this.songThumbnailUrl,
    this.artistId,
    this.artistName,
    this.artistThumbnailUrl,
  });

  factory SongHistoryItem.fromJson(Map<String, dynamic> json) {
    final song = json['song'] as Map<String, dynamic>?;
    final artist = song?['artist'] as Map<String, dynamic>?;
    return SongHistoryItem(
      timestamp: json['timestamp'] as String,
      listeners: json['listeners'] as int?,
      songId: song?['id'] as int?,
      songName: song?['name'] as String?,
      songThumbnailUrl: song?['thumbnail_url'] as String?,
      artistId: artist?['id'] as int?,
      artistName: artist?['name'] as String?,
      artistThumbnailUrl: artist?['thumbnail_url'] as String?,
    );
  }

  bool get hasSong => songName != null && songName!.isNotEmpty;

  /// [songName] as shown, starting with a capital letter like the live
  /// song ([NowPlayingSanitizer.capitalized]); the merge keeps it as sent.
  String? get displaySongName => _capitalized(songName);

  /// [artistName] as shown, starting with a capital letter.
  String? get displayArtistName => _capitalized(artistName);

  static String? _capitalized(String? text) =>
      text == null ? null : NowPlayingSanitizer.capitalized(text);

  DateTime get dateTime => DateTime.parse(timestamp);

  /// This item in the API's `now_playing` shape, so history rows and live
  /// rows go through the same merge. An item without a song id gives
  /// `song: null`, as does one whose artist lacks an id or name.
  Map<String, dynamic> toNowPlayingJson() => {
        'timestamp': timestamp,
        'listeners': listeners,
        'song': songId == null || songName == null
            ? null
            : {
                'id': songId,
                'name': songName,
                'thumbnail_url': songThumbnailUrl,
                'artist': artistId == null || artistName == null
                    ? null
                    : {
                        'id': artistId,
                        'name': artistName,
                        'thumbnail_url': artistThumbnailUrl,
                      },
              },
      };
}

/// Response from the stations-metadata-history API.
class SongHistoryResponse {
  final int stationId;
  final String stationSlug;
  final String stationTitle;
  final int fromTimestamp;
  final int toTimestamp;
  final int count;
  final List<SongHistoryItem> history;

  const SongHistoryResponse({
    required this.stationId,
    required this.stationSlug,
    required this.stationTitle,
    required this.fromTimestamp,
    required this.toTimestamp,
    required this.count,
    required this.history,
  });

  factory SongHistoryResponse.fromJson(Map<String, dynamic> json) {
    final historyList = (json['history'] as List?) ?? [];
    return SongHistoryResponse(
      stationId: json['station_id'] as int,
      stationSlug: json['station_slug'] as String,
      stationTitle: json['station_title'] as String,
      fromTimestamp: json['from_timestamp'] as int,
      toTimestamp: json['to_timestamp'] as int,
      count: json['count'] as int,
      history: historyList
          .whereType<Map<String, dynamic>>()
          .map((item) => SongHistoryItem.fromJson(item))
          .toList(),
    );
  }
}

/// Groups history items by date and hour for display.
class HistoryDateGroup {
  final String dateKey;
  final String dateLabel;
  final List<HistoryHourGroup> hours;

  const HistoryDateGroup({
    required this.dateKey,
    required this.dateLabel,
    required this.hours,
  });
}

class HistoryHourGroup {
  final String hourKey;
  final String hourLabel;
  final List<SongHistoryItem> songs;

  const HistoryHourGroup({
    required this.hourKey,
    required this.hourLabel,
    required this.songs,
  });
}

class SongHistoryService {
  static void _log(String message) {
    developer.log("SongHistoryService: $message");
  }

  /// A hung request must not stall the recently-played lists or the audible
  /// song resolution, which retries on its own schedule.
  static const _requestTimeout = Duration(seconds: 8);

  /// Fetches song history for a station within a time range.
  /// [fromTimestamp] and [toTimestamp] are Unix seconds; the server defaults
  /// a missing `from` to `now − 3600` and a missing `to` to now.
  static Future<SongHistoryResponse?> fetchHistory(
    String stationSlug, {
    int? fromTimestamp,
    int? toTimestamp,
    http.Client? client,
  }) async {
    try {
      final response = await _get(
          _historyUri(stationSlug, from: fromTimestamp, to: toTimestamp),
          client);
      if (response.statusCode != 200) {
        _log("History fetch failed: ${response.statusCode}");
        return null;
      }
      return _parseResponse(response.body);
    } catch (e) {
      _log("Error fetching history: $e");
      return null;
    }
  }

  /// One history window for the audible-song resolver: the rows in API order
  /// plus when the origin generated them. Null on an HTTP error, a timeout or
  /// an API error body (such as "to_timestamp cannot be in the future").
  static Future<HistoryPage?> fetchPage(
    String stationSlug,
    HistoryWindow window, {
    http.Client? client,
  }) async {
    try {
      final response = await _get(
          _historyUri(stationSlug, from: window.from, to: window.to), client);
      if (response.statusCode != 200) return null;
      final history = _parseResponse(response.body);
      if (history == null) return null;
      final rows = [
        for (final item in history.history)
          NowPlayingRow.fromNowPlayingJson(item.toNowPlayingJson()),
      ].whereType<NowPlayingRow>().toList();
      return HistoryPage(
          rows, AudibleSongPolicy.generationTime(response.headers));
    } catch (e) {
      _log("Error fetching history page: $e");
      return null;
    }
  }

  /// The songs of [items] that were heard by [cutoff], newest first.
  ///
  /// [cutoff] is the audible instant for a time-shifted station, so the
  /// "recently played" lists never show a song the listener has not reached.
  static List<SongHistoryItem> playedBefore(
    Iterable<SongHistoryItem> items,
    DateTime cutoff,
  ) =>
      items
          .where((item) => item.hasSong && !item.dateTime.isAfter(cutoff))
          .toList()
        ..sort((a, b) => b.dateTime.compareTo(a.dateTime));

  /// The first one-hour page of the history modal: it ends at the hour
  /// boundary after [cutoff], never later than [now].
  static HistoryWindow initialPage({
    required DateTime cutoff,
    required DateTime now,
  }) {
    const hourMs = 3600 * 1000;
    final ceilHour =
        (cutoff.millisecondsSinceEpoch + hourMs - 1) ~/ hourMs * 3600;
    final nowEpoch = now.millisecondsSinceEpoch ~/ 1000;
    final to = ceilHour < nowEpoch ? ceilHour : nowEpoch;
    return HistoryWindow(to - 3600, to);
  }

  static Uri _historyUri(String slug, {int? from, int? to}) {
    var url = '${CONSTANTS.STATIONS_METADATA_HISTORY_URL}'
        '?station_slug=${Uri.encodeComponent(slug)}';
    if (from != null) url += '&from_timestamp=$from';
    if (to != null) url += '&to_timestamp=$to';
    return Uri.parse(url);
  }

  /// GET through [client], or through a one-off client that is closed after.
  static Future<http.Response> _get(Uri uri, http.Client? client) async {
    if (client != null) return client.get(uri).timeout(_requestTimeout);
    final owned = http.Client();
    try {
      return await owned.get(uri).timeout(_requestTimeout);
    } finally {
      owned.close();
    }
  }

  /// The history payload, or null for an API error body (`data: null`).
  static SongHistoryResponse? _parseResponse(String body) {
    final jsonData = json.decode(body) as Map<String, dynamic>;
    final historyData = jsonData['data']?['stations_metadata_history'];
    return historyData is Map<String, dynamic>
        ? SongHistoryResponse.fromJson(historyData)
        : null;
  }

  /// Groups history items by date and hour for display, sorted descending.
  static List<HistoryDateGroup> groupByDateAndHour(List<SongHistoryItem> items) {
    final groups = <String, Map<String, List<SongHistoryItem>>>{};

    for (final item in items) {
      if (!item.hasSong) continue;
      final date = item.dateTime.toLocal();
      final dateKey = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final hourKey = '$dateKey-${date.hour.toString().padLeft(2, '0')}';

      groups.putIfAbsent(dateKey, () => {});
      groups[dateKey]!.putIfAbsent(hourKey, () => []);
      groups[dateKey]![hourKey]!.add(item);
    }

    final sortedDates = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final yesterdayKey = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';

    return sortedDates.map((dateKey) {
      final hourMap = groups[dateKey]!;
      final sortedHours = hourMap.keys.toList()..sort((a, b) => b.compareTo(a));

      String dateLabel;
      if (dateKey == today) {
        dateLabel = 'Azi';
      } else if (dateKey == yesterdayKey) {
        dateLabel = 'Ieri';
      } else {
        final parts = dateKey.split('-');
        final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        dateLabel = _formatDate(date);
      }

      final hours = sortedHours.map((hourKey) {
        final songs = hourMap[hourKey]!;
        songs.sort((a, b) => b.dateTime.compareTo(a.dateTime));
        final hour = songs.first.dateTime.toLocal().hour;
        return HistoryHourGroup(
          hourKey: hourKey,
          hourLabel: '${hour.toString().padLeft(2, '0')}:00 - ${hour.toString().padLeft(2, '0')}:59',
          songs: songs,
        );
      }).toList();

      return HistoryDateGroup(
        dateKey: dateKey,
        dateLabel: dateLabel,
        hours: hours,
      );
    }).toList();
  }

  static String _formatDate(DateTime date) {
    const days = ['luni', 'marți', 'miercuri', 'joi', 'vineri', 'sâmbătă', 'duminică'];
    const months = [
      'ianuarie', 'februarie', 'martie', 'aprilie', 'mai', 'iunie',
      'iulie', 'august', 'septembrie', 'octombrie', 'noiembrie', 'decembrie'
    ];
    final dayName = days[date.weekday - 1];
    final monthName = months[date.month - 1];
    return '$dayName, ${date.day} $monthName ${date.year}';
  }
}
