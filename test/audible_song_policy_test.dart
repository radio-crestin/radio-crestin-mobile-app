import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/audible_song_policy.dart';
import 'package:radio_crestin/services/hls_timeline.dart';
import 'package:radio_crestin/services/song_history_service.dart';

import 'helpers/hls_fixtures.dart' show readFixture;

void main() {
  final b = DateTime.utc(2026, 10, 11, 12);
  DateTime atB(num seconds) =>
      b.add(Duration(milliseconds: (seconds * 1000).round()));
  int epochOf(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  NowPlayingRow row(DateTime start, int? songId) => NowPlayingRow(
        startedAt: start,
        nowPlaying: {
          'timestamp': start.toIso8601String(),
          'song': songId == null ? null : {'id': songId, 'name': 'S$songId'},
        },
      );

  group('changeRow', () {
    test('window is [B - 1.5 s, B + 20 s]', () {
      expect(AudibleSongPolicy.changeRow([row(atB(-1.5), 1)], b)?.songId, 1);
      expect(AudibleSongPolicy.changeRow([row(atB(-1.6), 1)], b), isNull);
      expect(AudibleSongPolicy.changeRow([row(atB(20), 1)], b)?.songId, 1);
      expect(AudibleSongPolicy.changeRow([row(atB(20.1), 1)], b), isNull);
    });

    test('the earliest start wins, not the newest (a jingle at B+8)', () {
      final rows = [row(atB(8), 2), row(atB(0.5), 1), row(atB(15), 3)];
      expect(AudibleSongPolicy.changeRow(rows, b)?.songId, 1);
    });

    test('on equal starts the last tied row in API order wins (B3)', () {
      final rows = [row(atB(0.2), 31), row(atB(0.2), 32), row(atB(9), 33)];
      expect(AudibleSongPolicy.changeRow(rows, b)?.songId, 32);
    });

    test('rows of the song audible before B are skipped (R9)', () {
      final rows = [row(atB(1), 7), row(atB(1.001), 8)];
      expect(AudibleSongPolicy.changeRow(rows, b)?.songId, 7);
      expect(AudibleSongPolicy.changeRow(rows, b, songBefore: 7)?.songId, 8);
    });

    test('only rows of the previous song: not found (retry, then settle)', () {
      final rows = [row(atB(1), 7), row(atB(12), 7)];
      expect(AudibleSongPolicy.changeRow(rows, b, songBefore: 7), isNull);
    });

    test('a song-less change row is a change (source silent)', () {
      final found =
          AudibleSongPolicy.changeRow([row(atB(0.3), null)], b, songBefore: 7);
      expect(found, isNotNull);
      expect(found!.songId, isNull);
    });
  });

  group('rowAt', () {
    final a = atB(100);

    test('the newest row starting at or before A', () {
      final rows = [row(atB(0), 1), row(a, 2), row(atB(100.001), 3)];
      expect(AudibleSongPolicy.rowAt(rows, a)?.songId, 2);
    });

    test('ties: the last in API order', () {
      final rows = [row(atB(50), 1), row(atB(50), 2)];
      expect(AudibleSongPolicy.rowAt(rows, a)?.songId, 2);
    });

    test('nothing at or before A', () {
      expect(AudibleSongPolicy.rowAt([row(atB(101), 1)], a), isNull);
      expect(AudibleSongPolicy.rowAt(const [], a), isNull);
    });
  });

  test('isExactChangeRow is B ± 1.5 s', () {
    expect(AudibleSongPolicy.isExactChangeRow(row(atB(1.5), 1), b), isTrue);
    expect(AudibleSongPolicy.isExactChangeRow(row(atB(-1.5), 1), b), isTrue);
    expect(AudibleSongPolicy.isExactChangeRow(row(atB(1.6), 1), b), isFalse);
    expect(AudibleSongPolicy.isExactChangeRow(row(atB(8), 1), b), isFalse);
  });

  test('liveProvesAudible needs the cursor 60 s past A and a started row', () {
    final live = row(atB(-30), 1);
    bool proves(int cursorAfterA, {NowPlayingRow? r}) =>
        AudibleSongPolicy.liveProvesAudible(
            live: r ?? live, audible: b, liveCursor: epochOf(b) + cursorAfterA);
    expect(proves(59), isFalse);
    expect(proves(60), isTrue);
    expect(proves(600, r: row(atB(1), 2)), isFalse, reason: 'future row');
  });

  test('isSettled: generated at least 60 s after the instant', () {
    expect(AudibleSongPolicy.isSettled(atB(59), b), isFalse);
    expect(AudibleSongPolicy.isSettled(atB(60), b), isTrue);
    expect(AudibleSongPolicy.isSettled(null, b), isFalse);
  });

  group('generationTime (R11)', () {
    test('Last-Modified is the generation time', () {
      expect(
          AudibleSongPolicy.generationTime({
            'last-modified': 'Sun, 11 Oct 2026 11:53:10 GMT',
            'date': 'Sun, 11 Oct 2026 11:55:00 GMT',
            'age': '100',
          }),
          DateTime.utc(2026, 10, 11, 11, 53, 10));
    });

    test('without it, Date - Age (a cached copy)', () {
      expect(
          AudibleSongPolicy.generationTime({
            'date': 'Sun, 11 Oct 2026 11:55:00 GMT',
            'age': '100',
          }),
          DateTime.utc(2026, 10, 11, 11, 53, 20));
    });

    test('a Date alone or garbage is unknown', () {
      expect(
          AudibleSongPolicy.generationTime(
              {'date': 'Sun, 11 Oct 2026 11:55:00 GMT'}),
          isNull);
      expect(AudibleSongPolicy.generationTime({'last-modified': 'yesterday'}),
          isNull);
      expect(AudibleSongPolicy.generationTime(const {}), isNull);
    });
  });

  group('changeWindow', () {
    final bs = epochOf(b);

    test('[b-2, b+20+attempt]: a new key per attempt', () {
      for (var attempt = 0; attempt < 5; attempt++) {
        expect(
            AudibleSongPolicy.changeWindow(
                boundary: b, attempt: attempt, nowEpoch: bs + 300),
            HistoryWindow(bs - 2, bs + 20 + attempt));
      }
    });

    test('to is capped at now - 2 (instant mode)', () {
      expect(
          AudibleSongPolicy.changeWindow(
              boundary: b, attempt: 0, nowEpoch: bs + 8),
          HistoryWindow(bs - 2, bs + 6));
    });

    test('a fractional START-DATE floors', () {
      expect(
          AudibleSongPolicy.changeWindow(
              boundary: atB(0.716), attempt: 0, nowEpoch: bs + 300),
          HistoryWindow(bs - 2, bs + 20));
    });

    test('a device clock behind the boundary never inverts the window', () {
      final w = AudibleSongPolicy.changeWindow(
          boundary: b, attempt: 0, nowEpoch: bs - 10);
      expect(w.to, w.from);
    });
  });

  group('anchorWindow', () {
    final bs = epochOf(b);

    test('to = ceil10(A), from = to - 3600', () {
      expect(AudibleSongPolicy.anchorWindow(audible: atB(-138), nowEpoch: bs),
          HistoryWindow(bs - 130 - 3600, bs - 130));
      expect(AudibleSongPolicy.anchorWindow(audible: atB(-130), nowEpoch: bs),
          HistoryWindow(bs - 130 - 3600, bs - 130));
    });

    test('to is capped at now - 2', () {
      expect(AudibleSongPolicy.anchorWindow(audible: atB(-1), nowEpoch: bs).to,
          bs - 2);
    });
  });

  test('retry delays add up to 55 s', () {
    final total = AudibleSongPolicy.retryDelays
        .fold<Duration>(Duration.zero, (sum, d) => sum + d);
    expect(total, const Duration(seconds: 55));
  });

  group('nowPlayingFromHint', () {
    test('a complete B14 hint becomes an API-shaped now_playing', () {
      final json = AudibleSongPolicy.nowPlayingFromHint(
        const SongBoundaryHint(
          songId: 143962,
          title: '- Ai creat orice faptura',
          artist: 'Hristic',
          artistId: 191,
          thumbnailUrl: 'https://cdn.example.com/s.webp',
        ),
        atB(0),
      )!;
      expect(json['timestamp'], b.toIso8601String());
      expect(json['song'], {
        'id': 143962,
        'name': '- Ai creat orice faptura',
        'thumbnail_url': 'https://cdn.example.com/s.webp',
        'artist': {'id': 191, 'name': 'Hristic', 'thumbnail_url': null},
      });
    });

    test('title-only or blank-title hints are ignored', () {
      expect(
          AudibleSongPolicy.nowPlayingFromHint(
              const SongBoundaryHint(title: 'ICY text'), b),
          isNull);
      expect(
          AudibleSongPolicy.nowPlayingFromHint(
              const SongBoundaryHint(songId: 5, title: '  '), b),
          isNull);
      expect(AudibleSongPolicy.nowPlayingFromHint(null, b), isNull);
    });

    test('no artist gives a song without artist; a missing artist id is 0', () {
      final none = AudibleSongPolicy.nowPlayingFromHint(
          const SongBoundaryHint(songId: 5, title: 'T'), b)!;
      expect((none['song'] as Map)['artist'], isNull);
      final noId = AudibleSongPolicy.nowPlayingFromHint(
          const SongBoundaryHint(songId: 5, title: 'T', artist: 'A'), b)!;
      expect(((noId['song'] as Map)['artist'] as Map)['id'], 0);
    });
  });

  group('NowPlayingRow.fromNowPlayingJson', () {
    test('parses the start and the song id', () {
      final r = NowPlayingRow.fromNowPlayingJson({
        'timestamp': '2026-10-11T11:52:46.682876+00:00',
        'song': {'id': 143962, 'name': 'x'},
      })!;
      expect(r.startedAt, DateTime.utc(2026, 10, 11, 11, 52, 46, 682, 876));
      expect(r.songId, 143962);
    });

    test('null without a parseable timestamp; songId null without a song', () {
      expect(NowPlayingRow.fromNowPlayingJson({'song': null}), isNull);
      expect(NowPlayingRow.fromNowPlayingJson({'timestamp': 'soon'}), isNull);
      expect(NowPlayingRow.fromNowPlayingJson(null), isNull);
      expect(
          NowPlayingRow.fromNowPlayingJson(
                  {'timestamp': '2026-10-11T11:52:46Z', 'song': null})!
              .songId,
          isNull);
    });
  });

  test(
      'production fixture: rve-suceava EPOCH 1791719566 resolves to the '
      'history row stamped +0.68 s', () {
    final playlist = HlsPlaylistSnapshot.parse(
        readFixture('hls/rve-suceava.m3u8'),
        fetchedAt: DateTime.utc(2026, 10, 11, 11, 53, 12))!;
    final epoch = playlist.metadataChangedAt!;
    expect(epochOf(epoch), 1791719566);
    final boundary = playlist.songBoundaries
        .firstWhere((s) => s.at.difference(epoch).abs().inSeconds < 2);

    final body = json.decode(
            readFixture('metadata/rve-suceava-history-E1791719566.json'))
        as Map<String, dynamic>;
    final history = SongHistoryResponse.fromJson(
        body['data']['stations_metadata_history'] as Map<String, dynamic>);
    final rows = [
      for (final item in history.history)
        NowPlayingRow.fromNowPlayingJson(item.toNowPlayingJson())!,
    ];
    final window = AudibleSongPolicy.changeWindow(
        boundary: boundary.at, attempt: 0, nowEpoch: 1791719700);
    expect(window, HistoryWindow(history.fromTimestamp, history.toTimestamp));

    final change = AudibleSongPolicy.changeRow(rows, boundary.at)!;
    expect(change.songId, 143962);
    expect(change.nowPlaying['song']['name'], '- Ai creat orice faptura');
    expect(change.nowPlaying['song']['artist']['name'], 'Hristic');
  });
}
