import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:radio_crestin/constants.dart';

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

  DateTime get dateTime => DateTime.parse(timestamp);
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

  /// Fetches song history for a station within a time range.
  /// [fromTimestamp] and [toTimestamp] are Unix seconds.
  static Future<SongHistoryResponse?> fetchHistory(
    String stationSlug, {
    int? fromTimestamp,
    int? toTimestamp,
  }) async {
    var url = '${CONSTANTS.STATIONS_METADATA_HISTORY_URL}?station_slug=${Uri.encodeComponent(stationSlug)}';
    if (fromTimestamp != null) {
      url += '&from_timestamp=$fromTimestamp';
    }
    if (toTimestamp != null) {
      url += '&to_timestamp=$toTimestamp';
    }

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final historyData = jsonData['data']?['stations_metadata_history'];
        if (historyData is Map<String, dynamic>) {
          return SongHistoryResponse.fromJson(historyData);
        }
        return null;
      } else {
        _log("History fetch failed: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      _log("Error fetching history: $e");
      return null;
    }
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
