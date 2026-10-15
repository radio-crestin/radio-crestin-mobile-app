import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radio_crestin/services/audible_song_policy.dart';
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

    test('shows the song and artist capitalized, keeps them as sent', () {
      final item = SongHistoryItem.fromJson({
        'timestamp': '2026-04-15T12:34:56Z',
        'song': {
          'id': 1,
          'name': 'mergand pe calea vieti',
          'artist': {'id': 2, 'name': 'david dolha'},
        },
      });
      expect(item.displaySongName, 'Mergand pe calea vieti');
      expect(item.displayArtistName, 'David dolha');
      expect(item.songName, 'mergand pe calea vieti');
      expect(item.toNowPlayingJson()['song']['name'],
          'mergand pe calea vieti');
    });

    test('shows no song or artist when there is none', () {
      final item = SongHistoryItem.fromJson({
        'timestamp': '2026-04-15T12:34:56Z',
      });
      expect(item.displaySongName, isNull);
      expect(item.displayArtistName, isNull);
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
      // Anchor to the middle of the current hour so subtracting a few minutes
      // can't cross an hour boundary (grouping is by clock hour). Without this
      // the test flaked in the first 10 minutes of any hour.
      final now = DateTime.now().toUtc();
      final anchor = DateTime.utc(now.year, now.month, now.day, now.hour, 30);
      final t1 = anchor.subtract(const Duration(minutes: 5)).toIso8601String();
      final t2 = anchor.subtract(const Duration(minutes: 10)).toIso8601String();

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
  group('SongHistoryService.playedBefore', () {
    SongHistoryItem item(String timestamp, {String? name = 'Song'}) =>
        SongHistoryItem(timestamp: timestamp, songName: name);

    test('keeps songs heard by the cutoff, newest first', () {
      final played = SongHistoryService.playedBefore([
        item('2026-10-11T11:50:00Z', name: 'A'),
        item('2026-10-11T11:58:00Z', name: 'C'),
        item('2026-10-11T11:54:00Z', name: 'B'),
        item('2026-10-11T11:58:01Z', name: 'not heard yet'),
        item('2026-10-11T11:40:00Z', name: null),
      ], DateTime.utc(2026, 10, 11, 11, 58));
      expect(played.map((i) => i.songName), ['C', 'B', 'A']);
    });
  });

  group('SongHistoryService.initialPage', () {
    test('ends at the hour after the cutoff', () {
      final w = SongHistoryService.initialPage(
        cutoff: DateTime.utc(2026, 10, 11, 9, 59, 59),
        now: DateTime.utc(2026, 10, 11, 12),
      );
      final ten = DateTime.utc(2026, 10, 11, 10).millisecondsSinceEpoch ~/ 1000;
      expect(w, HistoryWindow(ten - 3600, ten));
    });

    test('a cutoff exactly on the hour is its own end', () {
      final w = SongHistoryService.initialPage(
        cutoff: DateTime.utc(2026, 10, 11, 10),
        now: DateTime.utc(2026, 10, 11, 12),
      );
      expect(w.to,
          DateTime.utc(2026, 10, 11, 10).millisecondsSinceEpoch ~/ 1000);
    });

    test('never later than now', () {
      final now = DateTime.utc(2026, 10, 11, 11, 57, 42);
      final w = SongHistoryService.initialPage(cutoff: now, now: now);
      expect(w.to, now.millisecondsSinceEpoch ~/ 1000);
      expect(w.from, w.to - 3600);
    });

    test('a past date (filter) gives that day\'s window', () {
      final w = SongHistoryService.initialPage(
        cutoff: DateTime.utc(2026, 10, 1, 21, 30),
        now: DateTime.utc(2026, 10, 11, 12),
      );
      expect(w.to,
          DateTime.utc(2026, 10, 1, 22).millisecondsSinceEpoch ~/ 1000);
    });
  });

  group('SongHistoryItem.toNowPlayingJson', () {
    test('rebuilds the API now_playing shape', () {
      const item = SongHistoryItem(
        timestamp: '2026-10-11T11:52:46.682876+00:00',
        listeners: 54,
        songId: 143962,
        songName: '- Ai creat orice faptura',
        artistId: 191,
        artistName: 'Hristic',
      );
      expect(item.toNowPlayingJson(), {
        'timestamp': '2026-10-11T11:52:46.682876+00:00',
        'listeners': 54,
        'song': {
          'id': 143962,
          'name': '- Ai creat orice faptura',
          'thumbnail_url': null,
          'artist': {'id': 191, 'name': 'Hristic', 'thumbnail_url': null},
        },
      });
    });

    test('an item without a song gives song: null', () {
      const item = SongHistoryItem(timestamp: '2026-10-11T11:52:46Z');
      expect(item.toNowPlayingJson()['song'], isNull);
    });
  });

  group('SongHistoryService.fetchPage', () {
    const window = HistoryWindow(1791719564, 1791719586);
    String body({bool withRow = true}) => json.encode({
          'data': {
            'stations_metadata_history': {
              'station_id': 43,
              'station_slug': 'rve-suceava',
              'station_title': 'RVE Suceava',
              'from_timestamp': window.from,
              'to_timestamp': window.to,
              'count': withRow ? 1 : 0,
              'history': [
                if (withRow)
                  {
                    'timestamp': '2026-10-11T11:52:46.682876+00:00',
                    'listeners': 54,
                    'song': {'id': 143962, 'name': 'Ai creat', 'artist': null},
                  },
              ],
            }
          }
        });

    test('rows in API order plus the Last-Modified generation time', () async {
      Uri? requested;
      final page = await SongHistoryService.fetchPage('rve-suceava', window,
          client: MockClient((request) async {
        requested = request.url;
        return http.Response(body(), 200,
            headers: {'last-modified': 'Sun, 11 Oct 2026 11:53:10 GMT'});
      }));

      expect(requested!.queryParameters, {
        'station_slug': 'rve-suceava',
        'from_timestamp': '1791719564',
        'to_timestamp': '1791719586',
      });
      expect(page!.rows.single.songId, 143962);
      expect(page.generatedAt, DateTime.utc(2026, 10, 11, 11, 53, 10));
    });

    test('without Last-Modified the generation time is unknown', () async {
      final page = await SongHistoryService.fetchPage('s', window,
          client: MockClient((_) async => http.Response(body(), 200)));
      expect(page!.generatedAt, isNull);
    });

    test('HTTP errors, API error bodies and exceptions give null', () async {
      Future<Object?> fetch(Future<http.Response> Function() respond) =>
          SongHistoryService.fetchPage('s', window,
              client: MockClient((_) => respond()));

      expect(await fetch(() async => http.Response('oops', 500)), isNull);
      expect(
          await fetch(() async => http.Response(
              json.encode({
                'data': null,
                'errors': [
                  {'message': 'to_timestamp cannot be in the future'}
                ],
              }),
              200)),
          isNull);
      expect(await fetch(() async => throw TimeoutException('slow')), isNull);
    });

    testWidgets('a hung request gives up after 8 s', (tester) async {
      var done = false;
      HistoryPage? page;
      unawaited(SongHistoryService.fetchPage('s', window,
              client: MockClient((_) => Completer<http.Response>().future))
          .then((p) {
        page = p;
        done = true;
      }));
      await tester.pump(const Duration(seconds: 7));
      expect(done, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(done, isTrue);
      expect(page, isNull);
    });
  });
}
