import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/youtube_iframe_player.dart';

/// Contracts for the YouTube player's fullscreen gestures and system chrome.
///
/// BUG (fixed here): the app's controls layer was a sibling stacked over
/// [YoutubeIframePlayer]. Since youtube_player_iframe 6.0 the WebView is
/// hoisted into an `OverlayPortal` floating above the page, so that sibling
/// painted and hit-tested BEHIND the picture — the fullscreen button on the
/// video was invisible and dead. The controls now go through
/// `YoutubePlayer.controlsBuilder`, which renders inside that same overlay.
///
/// The pieces testable without a live WebView are pinned here: the flick rule
/// ([youtubeFlickIntent]), the detector that applies it, and the rule for
/// which platforms may touch orientation on a fullscreen transition.

void main() {
  group('youtubeFlickIntent', () {
    // A quick upward flick: 100px in 100ms → 1000 px/s.
    const fast = Duration(milliseconds: 100);

    test('flick up enters fullscreen', () {
      // Arrange + Act.
      final intent = youtubeFlickIntent(
        travel: const Offset(0, -100),
        elapsed: fast,
        isFullscreen: false,
      );

      // Assert.
      expect(intent, YoutubeFlickIntent.enter);
    });

    test('flick down exits fullscreen', () {
      expect(
        youtubeFlickIntent(
          travel: const Offset(0, 100),
          elapsed: fast,
          isFullscreen: true,
        ),
        YoutubeFlickIntent.exit,
      );
    });

    test('a flick asking for the state already in place does nothing', () {
      // Up while already fullscreen, down while already inline.
      expect(
        youtubeFlickIntent(
          travel: const Offset(0, -100),
          elapsed: fast,
          isFullscreen: true,
        ),
        YoutubeFlickIntent.none,
      );
      expect(
        youtubeFlickIntent(
          travel: const Offset(0, 100),
          elapsed: fast,
          isFullscreen: false,
        ),
        YoutubeFlickIntent.none,
      );
    });

    test('a slow drag is not a flick', () {
      // 100px over 2s → 50 px/s, far under the threshold: this is somebody
      // moving a finger, not asking for fullscreen.
      expect(
        youtubeFlickIntent(
          travel: const Offset(0, -100),
          elapsed: const Duration(seconds: 2),
          isFullscreen: false,
        ),
        YoutubeFlickIntent.none,
      );
    });

    test('a tiny fast twitch is not a flick', () {
      expect(
        youtubeFlickIntent(
          travel: const Offset(0, -10),
          elapsed: const Duration(milliseconds: 8),
          isFullscreen: false,
        ),
        YoutubeFlickIntent.none,
      );
    });

    test('a mostly horizontal swipe is not a flick', () {
      // The scrubber drag lives on this surface — it must never be read as a
      // fullscreen request.
      expect(
        youtubeFlickIntent(
          travel: const Offset(200, -60),
          elapsed: fast,
          isFullscreen: false,
        ),
        YoutubeFlickIntent.none,
      );
    });

    test('a zero-length gesture is not a flick', () {
      expect(
        youtubeFlickIntent(
          travel: Offset.zero,
          elapsed: Duration.zero,
          isFullscreen: false,
        ),
        YoutubeFlickIntent.none,
      );
    });
  });

  group('YoutubeFlickDetector', () {
    Future<List<YoutubeFlickIntent>> pumpDetector(
      WidgetTester tester, {
      required bool isFullscreen,
    }) async {
      final intents = <YoutubeFlickIntent>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: YoutubeFlickDetector(
              isFullscreen: isFullscreen,
              onFlick: intents.add,
              child: const SizedBox(
                width: 300,
                height: 200,
                child: ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ));
      return intents;
    }

    testWidgets('a fling up over the player asks for fullscreen',
        (tester) async {
      // Arrange.
      final intents = await pumpDetector(tester, isFullscreen: false);

      // Act.
      await tester.fling(
        find.byType(YoutubeFlickDetector),
        const Offset(0, -120),
        1000,
      );
      await tester.pumpAndSettle();

      // Assert.
      expect(intents, [YoutubeFlickIntent.enter]);
    });

    testWidgets('a fling down while fullscreen asks to leave it',
        (tester) async {
      final intents = await pumpDetector(tester, isFullscreen: true);

      await tester.fling(
        find.byType(YoutubeFlickDetector),
        const Offset(0, 120),
        1000,
      );
      await tester.pumpAndSettle();

      expect(intents, [YoutubeFlickIntent.exit]);
    });

    testWidgets('a plain tap asks for nothing', (tester) async {
      final intents = await pumpDetector(tester, isFullscreen: false);

      await tester.tap(find.byType(YoutubeFlickDetector));
      await tester.pumpAndSettle();

      expect(intents, isEmpty);
    });

    testWidgets('the detector never steals the gesture from a scroll view',
        (tester) async {
      // Arrange: the player sits inside a list, exactly as it does in the
      // full player. Watching raw pointers (rather than entering the gesture
      // arena) is what keeps the list scrollable from on top of the video.
      final intents = <YoutubeFlickIntent>[];
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scrollController,
            children: [
              YoutubeFlickDetector(
                isFullscreen: false,
                onFlick: intents.add,
                child: const SizedBox(height: 200),
              ),
              for (var i = 0; i < 20; i++) SizedBox(height: 100, key: ValueKey(i)),
            ],
          ),
        ),
      ));

      // Act: drag slowly upward (20px per 200ms → 100 px/s, well under the
      // flick threshold), starting on the player. Timestamps are explicit —
      // a synthetic gesture reports Duration.zero otherwise, which would make
      // this pass for the wrong reason.
      var stamp = Duration.zero;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(YoutubeFlickDetector)),
      );
      for (var i = 0; i < 10; i++) {
        stamp += const Duration(milliseconds: 200);
        await gesture.moveBy(const Offset(0, -20), timeStamp: stamp);
        await tester.pump(const Duration(milliseconds: 200));
      }
      stamp += const Duration(milliseconds: 200);
      await gesture.up(timeStamp: stamp);
      await tester.pumpAndSettle();

      // Assert: the list scrolled, and no fullscreen was requested.
      expect(scrollController.offset, greaterThan(0));
      expect(intents, isEmpty);
    });
  });

  group('fullscreen system chrome', () {
    test('handhelds manage orientation and system bars', () {
      // Phone: fullscreen means landscape + immersive, exit restores portrait.
      expect(shouldApplyFullscreenSystemChrome(isTv: false), isTrue);
    });

    test('TV and desktop never pin an orientation', () {
      // Pinning portrait on a TV squeezes the large-screen shell into a
      // narrow column — what leaving an embedded YouTube item used to do.
      expect(shouldApplyFullscreenSystemChrome(isTv: true), isFalse);
    });
  });
}
