import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/audible_now_playing_resolver.dart';
import 'package:radio_crestin/services/audible_song_policy.dart';

import 'helpers/fake_metadata_backend.dart' show FakeClock;

/// One scripted history response; [delay] makes it slow.
class _Answer {
  const _Answer(this.rows, {this.generatedAt, this.delay, this.fails = false});
  final List<NowPlayingRow> rows;
  final DateTime? generatedAt;
  final Duration? delay;
  final bool fails;
}

void main() {
  final b = DateTime.utc(2026, 10, 11, 12);
  DateTime atB(num seconds) =>
      b.add(Duration(milliseconds: (seconds * 1000).round()));

  NowPlayingRow row(DateTime start, int songId) => NowPlayingRow(
        startedAt: start,
        nowPlaying: {
          'timestamp': start.toIso8601String(),
          'song': {'id': songId, 'name': 'S$songId'},
        },
      );

  late FakeClock clock;
  late List<HistoryWindow> windows;
  late List<_Answer> answers;
  late AudibleNowPlayingResolver resolver;

  setUp(() {
    clock = FakeClock(atB(120));
    windows = [];
    answers = [];
    resolver = AudibleNowPlayingResolver(
      fetchHistory: (slug, window) async {
        windows.add(window);
        final answer =
            answers.isEmpty ? const _Answer([]) : answers.removeAt(0);
        if (answer.delay != null) await clock.wait(answer.delay!);
        if (answer.fails) return null;
        return HistoryPage(answer.rows, answer.generatedAt);
      },
      now: clock.call,
      wait: clock.wait,
    );
  });

  Future<AudibleNowPlaying?> change({int? songBefore, NowPlayingRow? live}) =>
      resolver.resolveChange(
          stationId: 1,
          slug: 's',
          boundary: b,
          live: live,
          songBefore: songBefore);

  test(
      'a response without Last-Modified is never settled: all 5 attempts '
      'run, then null (R11)', () async {
    answers.addAll(List.filled(5, const _Answer([])));
    AudibleNowPlaying? result;
    var done = false;
    unawaited(change().then((r) {
      result = r;
      done = true;
    }));

    await clock.advance(const Duration(minutes: 2));

    expect(done, isTrue);
    expect(result, isNull);
    expect(windows, hasLength(5));
    expect(windows.map((w) => w.to - w.from), [22, 23, 24, 25, 26]);
  });

  test('a settled response without the row ends after one attempt', () async {
    answers.add(_Answer(const [], generatedAt: atB(60)));
    final result = change();
    await clock.settle();

    expect(await result, isNull);
    expect(windows, hasLength(1));
  });

  test('found on a retry once ingested; isBusy only while in flight', () async {
    answers
      ..add(_Answer(const [], generatedAt: atB(10)))
      ..add(_Answer([row(atB(0.4), 9)], generatedAt: atB(13)));
    final result = change();
    await clock.settle();
    expect(resolver.isBusy, isTrue);

    await clock.advance(const Duration(seconds: 3));

    final found = await result;
    expect(found?.row.songId, 9);
    expect(found?.source, AudibleSource.history);
    expect(found?.heardAt, b);
    expect(resolver.isBusy, isFalse);
  });

  test('a failed or throwing request counts as a retry', () async {
    answers
      ..add(const _Answer([], fails: true))
      ..add(_Answer([row(atB(0.4), 9)], generatedAt: atB(130)));
    final result = change();
    await clock.advance(const Duration(seconds: 3));

    expect((await result)?.row.songId, 9);
  });

  test('a newer request supersedes an older one in flight', () async {
    answers.add(_Answer([row(atB(0.4), 9)],
        generatedAt: atB(120), delay: const Duration(seconds: 5)));
    final older = change();
    await clock.settle();
    answers.add(_Answer([row(atB(0.4), 9)], generatedAt: atB(120)));
    final newer = change();
    await clock.advance(const Duration(seconds: 5));

    expect(await older, isNull);
    expect((await newer)?.row.songId, 9);
  });

  test('cancelAll makes in-flight work return null', () async {
    answers.add(const _Answer([], fails: true));
    final result = change();
    await clock.settle();
    resolver.cancelAll();
    await clock.advance(const Duration(minutes: 1));

    expect(await result, isNull);
    expect(windows, hasLength(1));
  });

  test(
      'not busy right after cancelAll, although the cancelled work still '
      'waits out its retry delay (station switch)', () async {
    answers.add(_Answer(const [], generatedAt: atB(10)));
    final result = change();
    await clock.settle();
    expect(resolver.isBusy, isTrue, reason: 'in the 3 s retry delay');

    resolver.cancelAll();

    expect(resolver.isBusy, isFalse);
    await clock.advance(const Duration(seconds: 3));
    expect(await result, isNull);
    expect(resolver.isBusy, isFalse);
  });

  test('a superseded resolution does not keep the newer one busy', () async {
    answers.add(_Answer(const [], generatedAt: atB(10)));
    final older = change();
    await clock.settle();
    final live = row(atB(0.6), 9);
    expect((await change(live: live))?.source, AudibleSource.live);

    expect(resolver.isBusy, isFalse);
    await clock.advance(const Duration(seconds: 3));
    expect(await older, isNull);
  });

  test(
      'the live row at B is used without a request unless it is the '
      'previous song', () async {
    final live = row(atB(0.6), 9);
    expect((await change(live: live))?.source, AudibleSource.live);
    expect(windows, isEmpty);

    answers.add(_Answer(const [], generatedAt: atB(120)));
    expect(await change(live: live, songBefore: 9), isNull);
    expect(windows, hasLength(1));
  });

  group('anchor', () {
    Future<AudibleNowPlaying?> anchor({
      NowPlayingRow? live,
      AudibleNowPlaying? heard,
      int liveCursor = 0,
    }) =>
        resolver.resolveAnchor(
            stationId: 1,
            slug: 's',
            audible: atB(100),
            live: live,
            heard: heard,
            liveCursor: liveCursor);

    AudibleNowPlaying heardSong(DateTime start, int songId,
            {int stationId = 1}) =>
        AudibleNowPlaying(
          stationId: stationId,
          row: row(start, songId),
          source: AudibleSource.history,
          heardAt: start,
        );

    test(
        'a stale copy missing the newest row never replaces a heard song '
        'that started by A with an older one', () async {
      // The copy predates song 2's ingestion; song 2 was resolved at its
      // boundary (B = A - 10 s) and is the station's audible song.
      answers.add(_Answer([row(atB(-300), 1)], generatedAt: atB(95)));
      final result = anchor(heard: heardSong(atB(90), 2));
      await clock.settle();

      final found = await result;
      expect(found?.row.songId, 2);
      expect(found?.source, AudibleSource.history);
      expect(found?.settled, isFalse);
    });

    test(
        'a newer row in the page still replaces the heard song; a heard '
        'song that starts after A (re-anchor further back) is ignored',
        () async {
      answers
        ..add(_Answer([row(atB(-300), 1), row(atB(95), 3)],
            generatedAt: atB(200)))
        ..add(_Answer([row(atB(-300), 1)], generatedAt: atB(200)));

      final newer = anchor(heard: heardSong(atB(90), 2));
      await clock.settle();
      expect((await newer)?.row.songId, 3);

      final further = anchor(heard: heardSong(atB(150), 2));
      await clock.settle();
      expect((await further)?.row.songId, 1);
    });

    test('another station\'s heard song is never a candidate', () async {
      answers.add(_Answer([row(atB(-300), 1)], generatedAt: atB(200)));
      final result = anchor(heard: heardSong(atB(90), 2, stationId: 7));
      await clock.settle();

      expect((await result)?.row.songId, 1);
    });

    test('a live row newer than a stale history copy wins', () async {
      answers.add(_Answer([row(atB(-300), 1)], generatedAt: atB(120)));
      final result = anchor(live: row(atB(50), 2));
      await clock.settle();

      final found = await result;
      expect(found?.row.songId, 2);
      expect(found?.source, AudibleSource.live);
    });

    test('an answer generated less than 60 s after A is unsettled', () async {
      answers.add(_Answer([row(atB(-300), 1)], generatedAt: atB(120)));
      final result = anchor();
      await clock.settle();

      final found = await result;
      expect(found?.row.songId, 1);
      expect(found?.settled, isFalse);
    });

    test('nothing at or before A keeps the current title (null)', () async {
      answers.add(_Answer([row(atB(150), 1)], generatedAt: atB(200)));
      final result = anchor(live: row(atB(150), 1));
      await clock.settle();

      expect(await result, isNull);
    });
  });
}
