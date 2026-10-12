import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/tv/tv_youtube_auto_advance.dart';
import 'package:radio_crestin/tv/widgets/tv_video_surface.dart';
import 'package:radio_crestin/types/playlist_item.dart';
import 'package:rxdart/rxdart.dart';

/// Tests for [TvYoutubeAutoAdvance]: TV and desktop cannot embed YouTube, so
/// the always-mounted shell moves the playlist past those items even while
/// Now Playing (and its "up next" card) is not on screen, unless the
/// listener paused. The card only renders the shell's countdown.
///
/// `testWidgets` supplies fake time; everything is created inside each test
/// body so the countdown timers run in that fake zone.
PlaylistItem _yt(int id) => PlaylistItem(
      id: id,
      order: id,
      type: PlaylistItemType.youtube,
      url: 'https://youtu.be/vid$id',
      title: 'YT $id',
    );

void main() {
  group('TvYoutubeAutoAdvance', () {
    late BehaviorSubject<PlaylistItem?> requests;
    late BehaviorSubject<bool> shouldPlay;
    late List<int> advanced;
    late TvYoutubeAutoAdvance autoAdvance;

    void start() {
      requests = BehaviorSubject<PlaylistItem?>.seeded(null);
      shouldPlay = BehaviorSubject<bool>.seeded(true);
      advanced = [];
      autoAdvance = TvYoutubeAutoAdvance(
        requests: requests.stream,
        shouldPlay: shouldPlay.stream,
        onAdvance: advanced.add,
      );
    }

    Future<void> stop() async {
      autoAdvance.dispose();
      await requests.close();
      await shouldPlay.close();
    }

    testWidgets('advances a YouTube item once the delay elapses',
        (tester) async {
      start();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 3));
      expect(advanced, isEmpty);

      await tester.pump(const Duration(seconds: 1));
      expect(advanced, [1], reason: 'reports the item id, for stale checks');
      await stop();
    });

    testWidgets('a null request cancels the pending countdown',
        (tester) async {
      start();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 2));
      requests.add(null); // playlist moved on / stopped
      await tester.pump(const Duration(seconds: 5));
      expect(advanced, isEmpty);
      await stop();
    });

    testWidgets('a newer item restarts the countdown for that item only',
        (tester) async {
      start();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 3));
      requests.add(_yt(2));
      await tester.pump(const Duration(seconds: 3));
      expect(advanced, isEmpty, reason: 'item 2 got its full delay');

      await tester.pump(const Duration(seconds: 1));
      expect(advanced, [2]);
      await stop();
    });

    testWidgets('re-arms when the same item is requested again',
        (tester) async {
      // A playlist whose only playable entry is one YouTube item wraps back
      // to it, so the same item is re-emitted after every advance.
      start();
      requests.add(_yt(7));
      await tester.pump(kTvYoutubeAutoAdvanceDelay);
      requests.add(_yt(7));
      await tester.pump(kTvYoutubeAutoAdvanceDelay);
      expect(advanced, [7, 7]);
      await stop();
    });

    testWidgets(
        'a pause stops the countdown: the next item never starts by itself',
        (tester) async {
      start();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 2));
      shouldPlay.add(false); // pause from the remote or the mini player
      await tester.pump(const Duration(seconds: 10));
      expect(advanced, isEmpty);
      expect(autoAdvance.countdown.value, isNull);
      await stop();
    });

    testWidgets('a resume restarts the full delay', (tester) async {
      start();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 3));
      shouldPlay.add(false);
      await tester.pump(const Duration(seconds: 1));
      shouldPlay.add(true);
      await tester.pump(const Duration(seconds: 3));
      expect(advanced, isEmpty, reason: 'the resume got a full delay');

      await tester.pump(const Duration(seconds: 1));
      expect(advanced, [1]);
      await stop();
    });

    testWidgets('an item requested while paused waits for the resume',
        (tester) async {
      start();
      shouldPlay.add(false);
      await tester.pump();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 10));
      expect(advanced, isEmpty);

      shouldPlay.add(true);
      await tester.pump(kTvYoutubeAutoAdvanceDelay);
      expect(advanced, [1]);
      await stop();
    });

    testWidgets('a repeated play intent keeps the running countdown',
        (tester) async {
      // playItemAt re-publishes `youtubeShouldPlay` for every item.
      start();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 3));
      final deadline = autoAdvance.countdown.value?.deadline;
      shouldPlay.add(true);
      await tester.pump();
      expect(autoAdvance.countdown.value?.deadline, deadline);

      await tester.pump(const Duration(seconds: 1));
      expect(advanced, [1]);
      await stop();
    });

    testWidgets('exposes the running countdown for the card',
        (tester) async {
      start();
      expect(autoAdvance.countdown.value, isNull);
      requests.add(_yt(3));
      await tester.pump();

      final running = autoAdvance.countdown.value;
      expect(running?.itemId, 3);
      final left = running!.deadline.difference(DateTime.now());
      expect(left, greaterThan(Duration.zero));
      expect(left, lessThanOrEqualTo(kTvYoutubeAutoAdvanceDelay));

      requests.add(null);
      await tester.pump();
      expect(autoAdvance.countdown.value, isNull);
      await stop();
    });

    testWidgets('dispose cancels the pending countdown', (tester) async {
      start();
      requests.add(_yt(1));
      await tester.pump(const Duration(seconds: 1));
      await stop();
      await tester.pump(const Duration(seconds: 5));
      expect(advanced, isEmpty);
    });
  });

  group('TvYoutubeUpNextCard', () {
    late ValueNotifier<TvYoutubeCountdown?> countdown;
    late int skips;

    Future<void> pumpCard(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvYoutubeUpNextCard(
            item: _yt(1),
            countdown: countdown,
            onSkip: () => skips++,
          ),
        ),
      ));
    }

    double barValue(WidgetTester tester) => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;

    setUp(() {
      countdown = ValueNotifier(null);
      skips = 0;
    });

    tearDown(() => countdown.dispose());

    testWidgets(
        'opened partway through, the bar starts from the elapsed time and '
        'ends at the shell deadline', (tester) async {
      // The shell armed 3 s ago: 1 s of the 4 s countdown is left.
      countdown.value = (
        itemId: 1,
        deadline: DateTime.now().add(const Duration(seconds: 1)),
      );
      await pumpCard(tester);

      expect(find.text('Se redă următorul element…'), findsOneWidget);
      expect(barValue(tester), closeTo(0.75, 0.05));

      await tester.pump(const Duration(seconds: 1));
      expect(barValue(tester), 1.0);
    });

    testWidgets('waits, with an empty bar, while the listener paused',
        (tester) async {
      await pumpCard(tester);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('În pauză'), findsOneWidget);
      expect(barValue(tester), 0.0);
    });

    testWidgets("another item's countdown shows as paused", (tester) async {
      countdown.value = (
        itemId: 2,
        deadline: DateTime.now().add(kTvYoutubeAutoAdvanceDelay),
      );
      await pumpCard(tester);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('În pauză'), findsOneWidget);
    });

    testWidgets('skip (remote select) moves past the item at once',
        (tester) async {
      await pumpCard(tester);
      await tester.pump(); // the skip button takes the autofocus

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(skips, 1);
    });
  });
}
