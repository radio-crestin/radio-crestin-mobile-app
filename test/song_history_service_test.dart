import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/song_history_service.dart';

void main() {
  group('SongHistoryItem.fromJson', () {
    test('parses a fully-populated payload', () {
      final item = SongHistoryItem.fromJson({
        'timestamp': '2026-04-15T12:34:56Z',
        'listeners': 42,
        'song': {
          'id': 7,
          'name': 'Amazing Grace',
          'thumbnail_url': 'https://example.com/song.png',
          'artist': {
            'id': 9,
            'name': 'Choir',
            'thumbnail_url': 'https://example.com/artist.png',
          },
        },
      });

      expect(item.timestamp, '2026-04-15T12:34:56Z');
      expect(item.listeners, 42);
      expect(item.songId, 7);
      expect(item.songName, 'Amazing Grace');
      expect(item.songThumbnailUrl, 'https://example.com/song.png');
      expect(item.artistId, 9);
      expect(item.artistName, 'Choir');
      expect(item.artistThumbnailUrl, 'https://example.com/artist.png');
      expect(item.hasSong, true);
      expect(item.dateTime, DateTime.parse('2026-04-15T12:34:56Z'));
    });

    test('parses payload with no song', () {
      final item = SongHistoryItem.fromJson({
        'timestamp': '2026-04-15T12:34:56Z',
        'listeners': null,
      });
      expect(item.songId, isNull);
      expect(item.songName, isNull);
      expect(item.artistName, isNull);
      expect(item.hasSong, false);
    });

    test('hasSong is false for empty song name', () {
      final item = SongHistoryItem.fromJson({
        'timestamp': '2026-04-15T12:34:56Z',
        'song': {'name': ''},
      });
      expect(item.hasSong, false);
    });
  });

  group('SongHistoryResponse.fromJson', () {
    test('parses full response with multiple items', () {
      final response = SongHistoryResponse.fromJson({
        'station_id': 1,
        'station_slug': 'radio-emanuel',
        'station_title': 'Radio Emanuel',
        'from_timestamp': 1700000000,
        'to_timestamp': 1700003600,
        'count': 2,
        'history': [
          {
            'timestamp': '2026-04-15T10:00:00Z',
            'song': {'name': 'Song A'},
          },
          {
            'timestamp': '2026-04-15T11:00:00Z',
            'song': {'name': 'Song B'},
          },
        ],
      });
      expect(response.stationId, 1);
      expect(response.stationSlug, 'radio-emanuel');
      expect(response.stationTitle, 'Radio Emanuel');
      expect(response.fromTimestamp, 1700000000);
      expect(response.toTimestamp, 1700003600);
      expect(response.count, 2);
      expect(response.history, hasLength(2));
      expect(response.history[0].songName, 'Song A');
    });

    test('handles missing history list as empty', () {
      final response = SongHistoryResponse.fromJson({
        'station_id': 1,
        'station_slug': 's',
        'station_title': 't',
        'from_timestamp': 0,
        'to_timestamp': 0,
        'count': 0,
      });
      expect(response.history, isEmpty);
    });

    test('skips non-map entries in history list', () {
      final response = SongHistoryResponse.fromJson({
        'station_id': 1,
        'station_slug': 's',
        'station_title': 't',
        'from_timestamp': 0,
        'to_timestamp': 0,
        'count': 1,
        'history': [
          'garbage',
          {'timestamp': '2026-04-15T10:00:00Z'},
          null,
        ],
      });
      expect(response.history, hasLength(1));
    });
  });

  group('SongHistoryService.groupByDateAndHour', () {
    SongHistoryItem item(String timestamp, {String name = 'Song'}) {
      return SongHistoryItem(timestamp: timestamp, songName: name);
    }

    test('returns empty for empty input', () {
      expect(SongHistoryService.groupByDateAndHour([]), isEmpty);
    });

    test('drops items without a song', () {
      final groups = SongHistoryService.groupByDateAndHour([
        SongHistoryItem(timestamp: '2026-04-15T10:00:00Z'), // no song
        item('2026-04-15T10:01:00Z'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.first.hours.first.songs, hasLength(1));
    });

    test('groups items in the same hour into one HistoryHourGroup', () {
      final now = DateTime.now().toUtc();
      final t1 = now.subtract(const Duration(minutes: 5)).toIso8601String();
      final t2 = now.subtract(const Duration(minutes: 10)).toIso8601String();

      final groups = SongHistoryService.groupByDateAndHour([
        item(t1, name: 'A'),
        item(t2, name: 'B'),
      ]);

      // One date group, one hour group, two songs
      expect(groups, hasLength(1));
      expect(groups.first.hours, hasLength(1));
      expect(groups.first.hours.first.songs, hasLength(2));
    });

    test('songs within an hour are sorted descending by time', () {
      final now = DateTime.now();
      final earlier = DateTime(now.year, now.month, now.day, 10, 5)
          .toUtc()
          .toIso8601String();
      final later = DateTime(now.year, now.month, now.day, 10, 30)
          .toUtc()
          .toIso8601String();

      final groups = SongHistoryService.groupByDateAndHour([
        item(earlier, name: 'Earlier'),
        item(later, name: 'Later'),
      ]);

      final songs = groups.first.hours.first.songs;
      expect(songs.first.songName, 'Later');
      expect(songs.last.songName, 'Earlier');
    });

    test('today bucket gets "Azi" label', () {
      final now = DateTime.now();
      final ts = DateTime(now.year, now.month, now.day, now.hour, 5)
          .toUtc()
          .toIso8601String();

      final groups = SongHistoryService.groupByDateAndHour([item(ts)]);
      expect(groups.first.dateLabel, 'Azi');
    });

    test('yesterday bucket gets "Ieri" label', () {
      final yesterday =
          DateTime.now().subtract(const Duration(days: 1));
      final ts = DateTime(
        yesterday.year,
        yesterday.month,
        yesterday.day,
        12,
      ).toUtc().toIso8601String();

      final groups = SongHistoryService.groupByDateAndHour([item(ts)]);
      expect(groups.first.dateLabel, 'Ieri');
    });

    test('older dates get a Romanian formatted weekday label', () {
      // 2026-04-15 was a Wednesday (miercuri)
      final groups = SongHistoryService.groupByDateAndHour([
        item('2026-04-15T10:00:00Z'),
      ]);
      // Could be 14 or 15 depending on local TZ — accept either
      expect(
        groups.first.dateLabel,
        anyOf(
          equals('miercuri, 15 aprilie 2026'),
          equals('marți, 14 aprilie 2026'),
        ),
      );
    });

    test('multiple dates returned newest-first', () {
      final groups = SongHistoryService.groupByDateAndHour([
        item('2026-04-10T10:00:00Z', name: 'Older'),
        item('2026-04-15T10:00:00Z', name: 'Newer'),
      ]);
      expect(groups, hasLength(2));
      expect(groups.first.dateKey.compareTo(groups.last.dateKey),
          greaterThan(0));
    });

    test('hourLabel is "HH:00 - HH:59"', () {
      final groups = SongHistoryService.groupByDateAndHour([
        item('2026-04-15T13:23:00Z'),
      ]);
      // Format with two-digit hour, regardless of TZ shift
      expect(groups.first.hours.first.hourLabel, matches(r'^\d{2}:00 - \d{2}:59$'));
    });
  });
}
