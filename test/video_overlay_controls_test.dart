import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/player_video_surface.dart';
import 'package:radio_crestin/widgets/video_overlay_controls.dart';

/// Tests for the YouTube-style [VideoOverlayControls]: time formatting, the
/// double-tap seek arithmetic, control-size constants, auto-hide/visibility
/// toggling, live-vs-VOD bottom bars, and the transport gating.
void main() {
  group('formatOverlayTime', () {
    test('formats sub-minute and minute durations as m:ss', () {
      expect(formatOverlayTime(const Duration(seconds: 5)), '0:05');
      expect(formatOverlayTime(const Duration(seconds: 45)), '0:45');
      expect(formatOverlayTime(const Duration(minutes: 3, seconds: 7)), '3:07');
      expect(
          formatOverlayTime(const Duration(minutes: 12, seconds: 0)), '12:00');
    });

    test('formats hour-plus durations as h:mm:ss', () {
      expect(
          formatOverlayTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
    });

    test('clamps negatives to 0:00 and zero is 0:00', () {
      expect(formatOverlayTime(const Duration(seconds: -5)), '0:00');
      expect(formatOverlayTime(Duration.zero), '0:00');
    });
  });

  group('computeDoubleTapSeek', () {
    test('forward adds 10s, backward subtracts 10s', () {
      expect(
        computeDoubleTapSeek(
            position: const Duration(seconds: 30),
            duration: const Duration(minutes: 1),
            forward: true),
        const Duration(seconds: 40),
      );
      expect(
        computeDoubleTapSeek(
            position: const Duration(seconds: 30),
            duration: const Duration(minutes: 1),
            forward: false),
        const Duration(seconds: 20),
      );
    });

    test('clamps at zero when seeking back past the start', () {
      expect(
        computeDoubleTapSeek(
            position: const Duration(seconds: 4),
            duration: const Duration(minutes: 1),
            forward: false),
        Duration.zero,
      );
    });

    test('clamps at the total when seeking forward past the end', () {
      expect(
        computeDoubleTapSeek(
            position: const Duration(seconds: 55),
            duration: const Duration(minutes: 1),
            forward: true),
        const Duration(minutes: 1),
      );
    });

    test('unknown duration still allows forward seeking', () {
      expect(
        computeDoubleTapSeek(
            position: const Duration(seconds: 10),
            duration: null,
            forward: true),
        const Duration(seconds: 20),
      );
    });
  });

  group('control size constants', () {
    test('play control is 56', () {
      expect(kOverlayPlayButtonSize, 56.0);
    });
  });

  group('videoControlsAutoHideDelay', () {
    test('inline waits 20s of inactivity, fullscreen 5s', () {
      expect(kInlineControlsAutoHideDelay, const Duration(seconds: 20));
      expect(kFullscreenControlsAutoHideDelay, const Duration(seconds: 5));
      expect(videoControlsAutoHideDelay(isFullscreen: false),
          const Duration(seconds: 20));
      expect(videoControlsAutoHideDelay(isFullscreen: true),
          const Duration(seconds: 5));
    });

    test('every surface reads its delay from the one config', () {
      // One product decision ("how long do controls linger over a moving
      // picture?"), one place — the phone's fullscreen and the TV's remote
      // deliberately agree.
      expect(videoControlsAutoHideDelayFor(VideoControlsSurface.inline),
          kInlineControlsAutoHideDelay);
      expect(videoControlsAutoHideDelayFor(VideoControlsSurface.fullscreen),
          kFullscreenControlsAutoHideDelay);
      expect(videoControlsAutoHideDelayFor(VideoControlsSurface.tv),
          kTvVideoChromeAutoHideDelay);
      expect(kFullscreenControlsAutoHideDelay, kTvVideoChromeAutoHideDelay);
    });
  });

  group('shouldShowVideoControls', () {
    test('playing + timer elapsed hides the controls', () {
      expect(
        shouldShowVideoControls(
            userVisible: false, playing: true, buffering: false),
        isFalse,
      );
    });

    test('paused always keeps the controls up, timer or not', () {
      expect(
        shouldShowVideoControls(
            userVisible: false, playing: false, buffering: false),
        isTrue,
      );
    });

    test('buffering keeps the controls up even while playing', () {
      expect(
        shouldShowVideoControls(
            userVisible: false, playing: true, buffering: true),
        isTrue,
      );
    });

    test('a fresh interaction shows them', () {
      expect(
        shouldShowVideoControls(
            userVisible: true, playing: true, buffering: false),
        isTrue,
      );
    });
  });

  group('VideoOverlayControls widget', () {
    late StreamController<bool> playing;
    late StreamController<bool> buffering;
    late StreamController<Duration> position;
    late StreamController<Duration> duration;
    late StreamController<bool> indefinite;
    late StreamController<bool> seeking;

    setUp(() {
      playing = StreamController<bool>.broadcast();
      buffering = StreamController<bool>.broadcast();
      position = StreamController<Duration>.broadcast();
      duration = StreamController<Duration>.broadcast();
      indefinite = StreamController<bool>.broadcast();
      seeking = StreamController<bool>.broadcast();
    });

    tearDown(() {
      playing.close();
      buffering.close();
      position.close();
      duration.close();
      indefinite.close();
      seeking.close();
    });

    Widget build({
      bool initialPlaying = false,
      bool initialBuffering = false,
      bool isLive = false,
      bool isFullscreen = false,
      bool useSeekingStream = false,
      Duration initialPosition = Duration.zero,
      Duration? initialDuration,
      Duration? fallbackDuration,
      ValueChanged<Duration>? onSeek,
      VoidCallback? onToggleFullscreen,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: VideoOverlayControls(
                playingStream: playing.stream,
                initialPlaying: initialPlaying,
                bufferingStream: buffering.stream,
                initialBuffering: initialBuffering,
                positionStream: position.stream,
                initialPosition: initialPosition,
                durationStream: duration.stream,
                initialDuration: initialDuration,
                fallbackDuration: fallbackDuration,
                title: 'Emisiune live • Radio Creștin',
                isLive: isLive,
                indefiniteStream: indefinite.stream,
                initialIndefinite: isLive,
                seekingStream: useSeekingStream ? seeking.stream : null,
                isFullscreen: isFullscreen,
                onPlay: () {},
                onPause: () {},
                onSeek: onSeek,
                onToggleFullscreen: onToggleFullscreen,
              ),
            ),
          ),
        ),
      );
    }

    double controlsOpacity(WidgetTester tester) {
      final opacity = tester.widget<AnimatedOpacity>(
          find.byKey(const ValueKey('video-overlay-controls')));
      return opacity.opacity;
    }

    testWidgets('paused controls stay visible (never auto-hide)',
        (tester) async {
      await tester.pumpWidget(build(initialPlaying: false));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);

      // Well past the fullscreen auto-hide window — still visible while paused.
      await tester.pump(kFullscreenControlsAutoHideDelay +
          const Duration(seconds: 2));
      expect(controlsOpacity(tester), 1.0);
    });

    testWidgets(
        'fullscreen playing controls auto-hide after ~5s, tap brings them back',
        (tester) async {
      await tester.pumpWidget(build(initialPlaying: true, isFullscreen: true));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);

      await tester.pump(kFullscreenControlsAutoHideDelay +
          const Duration(seconds: 1));
      expect(controlsOpacity(tester), 0.0);

      // Any tap on the (now pass-through) surface toggles controls back on.
      await tester.tapAt(tester.getCenter(find.byType(VideoOverlayControls)));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);
    });

    testWidgets(
        'fullscreen: buffering shows a single spinner in the play '
        'button, controls stay visible', (tester) async {
      await tester
          .pumpWidget(build(initialBuffering: true, isFullscreen: true));
      await tester.pump();
      // Exactly one spinner (in the play/pause button), not a separate center
      // spinner plus a transport spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Standard styling per CLAUDE.md: strokeWidth 2.5 + brand color.
      final spinner = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator));
      expect(spinner.strokeWidth, 2.5);
      expect(spinner.valueColor?.value,
          AppColors.primary);
      // Controls remain visible while buffering (no longer hidden).
      expect(controlsOpacity(tester), 1.0);
      // The play/pause glyph is replaced by the spinner while buffering.
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    });

    testWidgets(
        'inline: buffering shows a single centered spinner but no '
        'center transport — play/skip stay on the below-title transport',
        (tester) async {
      await tester.pumpWidget(build(
        initialBuffering: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();
      // A standalone standard spinner so loading is visible on the surface.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final spinner = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator));
      expect(spinner.strokeWidth, 2.5);
      expect(spinner.valueColor?.value,
          AppColors.primary);
      // Still no transport controls on the inline surface.
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);
      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
      // The corner fullscreen button IS on the surface inline.
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    });

    testWidgets('inline: no spinner when not buffering', (tester) async {
      await tester.pumpWidget(build(onToggleFullscreen: () {}));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'REGRESSION: buffering flapping faster than the fade never throws '
        '"Duplicate keys found" (inline)', (tester) async {
      // A live TV stream rebuffers repeatedly; the spinner child therefore
      // comes back while its previous instance is still fading out. The
      // switcher used to reuse the child's key for its internal Stack entry,
      // putting the same key in that Stack twice.
      await tester.pumpWidget(build(
        initialPlaying: true,
        initialBuffering: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      for (var i = 0; i < 4; i++) {
        buffering.add(i.isEven ? false : true);
        // 20ms ≪ the 150ms fade, so the outgoing child is still on screen.
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.takeException(), isNull);
      }

      // Settled back on buffering: exactly one spinner in the tree.
      buffering.add(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets(
        'REGRESSION: buffering flapping faster than the fade never throws '
        '"Duplicate keys found" (fullscreen play button)', (tester) async {
      await tester.pumpWidget(build(
        initialPlaying: true,
        initialBuffering: true,
        isFullscreen: true,
      ));
      await tester.pump();

      for (var i = 0; i < 4; i++) {
        buffering.add(i.isEven ? false : true);
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.takeException(), isNull);
      }

      buffering.add(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets(
        'a live stream never gets a scrubber, however long its window reads',
        (tester) async {
      // Neither engine can honour a seek inside a live window, so a draggable
      // thumb there promises something it cannot deliver.
      await tester.pumpWidget(build(
        isLive: true,
        onSeek: (_) {},
        initialDuration: const Duration(minutes: 11),
      ));
      await tester.pump();
      expect(find.byType(LivePill), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets(
        'media the engine flags as indefinite loses its scrubber too',
        (tester) async {
      // Arrange: a VOD-looking surface that reports a length…
      await tester.pumpWidget(build(
        isLive: false,
        onSeek: (_) {},
        initialDuration: const Duration(minutes: 11),
      ));
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);

      // Act: …until the service says the media has no timeline at all.
      indefinite.add(true);
      await tester.pump();
      await tester.pump();

      // Assert.
      expect(find.byType(Slider), findsNothing);
    });


    testWidgets(
        'releasing the scrubber holds the thumb at the target while the seek '
        'is in flight', (tester) async {
      // Arrange: a 10-minute VOD whose engine will keep reporting the OLD
      // position for a moment after the seek — the snap-back that used to
      // yank the thumb out from under the finger.
      Duration? seeked;
      await tester.pumpWidget(build(
        initialPlaying: true,
        onSeek: (d) => seeked = d,
        initialDuration: const Duration(minutes: 10),
        useSeekingStream: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();

      // Act: drag and release.
      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pump();
      expect(seeked, isNotNull);
      final target = tester.widget<Slider>(find.byType(Slider)).value;
      expect(target, greaterThan(0));

      // The service reports the seek in flight, and the engine keeps sending
      // its stale playhead.
      seeking.add(true);
      position.add(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump();

      // Assert: the thumb has not moved, and the spinner says "loading".
      expect(tester.widget<Slider>(find.byType(Slider)).value, target);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Let the double-tap recognizer's own timer expire.
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('the thumb tracks the engine again once the seek settles',
        (tester) async {
      // Arrange.
      await tester.pumpWidget(build(
        initialPlaying: true,
        onSeek: (_) {},
        initialDuration: const Duration(minutes: 10),
        useSeekingStream: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();
      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pump();
      seeking.add(true);
      await tester.pump();
      await tester.pump();

      // Act: the engine lands and the service clears its seeking flag.
      seeking.add(false);
      position.add(const Duration(minutes: 5));
      await tester.pump();
      await tester.pump();

      // Assert.
      expect(
        tester.widget<Slider>(find.byType(Slider)).value,
        const Duration(minutes: 5).inMilliseconds.toDouble(),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('a held thumb is released even if the seek never settles',
        (tester) async {
      // Arrange: no "settled" ever arrives (a dropped connection mid-scrub).
      await tester.pumpWidget(build(
        initialPlaying: true,
        onSeek: (_) {},
        initialDuration: const Duration(minutes: 10),
        useSeekingStream: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();
      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pump();

      // Act: past the hold cap, with the engine reporting a real position.
      await tester.pump(const Duration(seconds: 6));
      position.add(const Duration(minutes: 2));
      await tester.pump();
      await tester.pump();

      // Assert: the UI is never permanently stuck on a stale target.
      expect(
        tester.widget<Slider>(find.byType(Slider)).value,
        const Duration(minutes: 2).inMilliseconds.toDouble(),
      );
    });

    testWidgets('a VOD with no plausible length shows no scrubber',
        (tester) async {
      await tester.pumpWidget(build(
        isLive: false,
        onSeek: (_) {},
        initialDuration: Duration.zero,
      ));
      await tester.pump();
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('live variant shows the LIVE pill and no seek bar',
        (tester) async {
      await tester.pumpWidget(build(isLive: true));
      await tester.pump();
      expect(find.byType(LivePill), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('VOD variant shows a seek bar and no LIVE pill',
        (tester) async {
      await tester.pumpWidget(build(
        isLive: false,
        onSeek: (_) {},
        initialDuration: const Duration(minutes: 1),
      ));
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(LivePill), findsNothing);
    });

    testWidgets(
        'fallbackDuration enables the seek bar before the player '
        'reports a duration', (tester) async {
      await tester.pumpWidget(build(
        isLive: false,
        onSeek: (_) {},
        initialDuration: null, // player has not reported a duration yet
        fallbackDuration: const Duration(minutes: 2),
      ));
      await tester.pump();
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.onChanged, isNotNull); // enabled via the fallback
      expect(slider.max, const Duration(minutes: 2).inMilliseconds.toDouble());
    });

    testWidgets(
        'fullscreen center shows ONLY play/pause — no prev/next in the middle',
        (tester) async {
      await tester
          .pumpWidget(build(isFullscreen: true, onToggleFullscreen: () {}));
      await tester.pump();
      // Center is play/pause only (explicit user feedback): the middle no
      // longer carries prev/next/fullscreen. Skipping stays on the playlist
      // section's below-video transport; fullscreen-exit lives in the bottom
      // bar (its own fullscreen glyph below).
      expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);
      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      // The fullscreen-exit control is present (in the bottom bar), not absent.
      expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    });

    testWidgets(
        'fullscreen: exit-fullscreen button sits in the BOTTOM-RIGHT corner '
        'and fires its callback', (tester) async {
      var exited = false;
      await tester.pumpWidget(build(
        isFullscreen: true,
        onToggleFullscreen: () => exited = true,
      ));
      await tester.pump();

      final exit = find.byIcon(Icons.fullscreen_exit_rounded);
      expect(exit, findsOneWidget);

      // Pinned to the bottom-right quadrant of the overlay (YouTube-style).
      final center = tester.getCenter(find.byType(VideoOverlayControls));
      final exitCenter = tester.getCenter(exit);
      expect(exitCenter.dx, greaterThan(center.dx));
      expect(exitCenter.dy, greaterThan(center.dy));

      await tester.tap(exit);
      await tester.pump();
      expect(exited, isTrue);
    });

    testWidgets(
        'the quality picker is gone — the corner always carries fullscreen',
        (tester) async {
      // The adaptive stream already picks a variant better than a person can,
      // and the corner is far more useful as a permanent fullscreen toggle.
      await tester.pumpWidget(build(
        isFullscreen: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();
      expect(find.byIcon(Icons.high_quality_rounded), findsNothing);
      expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    });

    testWidgets('the fullscreen button is the same disc as play/pause',
        (tester) async {
      // Arrange: fullscreen shows both, so their footprints are comparable.
      await tester.pumpWidget(build(
        isFullscreen: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();

      // Assert.
      final buttons = tester.widgetList<OverlayCircleButton>(
          find.byType(OverlayCircleButton));
      expect(buttons.length, greaterThanOrEqualTo(2));
      for (final b in buttons) {
        expect(b.size, kOverlayPlayButtonSize);
      }
    });

    // Runs a two-finger pinch on the overlay: both pointers start around the
    // surface center and move by [moveA]/[moveB] before lifting.
    Future<void> pinch(
      WidgetTester tester, {
      required Offset startA,
      required Offset startB,
      required Offset moveA,
      required Offset moveB,
    }) async {
      final center = tester.getCenter(find.byType(VideoOverlayControls));
      final g1 = await tester.startGesture(center + startA);
      final g2 = await tester.startGesture(center + startB);
      await tester.pump();
      await g1.moveBy(moveA);
      await g2.moveBy(moveB);
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pump();
    }

    testWidgets('pinch-out inline enters fullscreen exactly once',
        (tester) async {
      var toggles = 0;
      await tester.pumpWidget(build(onToggleFullscreen: () => toggles++));
      await tester.pump();

      // Fingers 60px apart spreading to 180px (scale 3.0 > enter threshold).
      await pinch(
        tester,
        startA: const Offset(-30, 0),
        startB: const Offset(30, 0),
        moveA: const Offset(-60, 0),
        moveB: const Offset(60, 0),
      );
      expect(toggles, 1);
    });

    testWidgets(
        'pinch keeps toggling once per gesture even when moving '
        'further past the threshold', (tester) async {
      var toggles = 0;
      await tester.pumpWidget(build(onToggleFullscreen: () => toggles++));
      await tester.pump();

      final center = tester.getCenter(find.byType(VideoOverlayControls));
      final g1 = await tester.startGesture(center + const Offset(-30, 0));
      final g2 = await tester.startGesture(center + const Offset(30, 0));
      await tester.pump();
      // Cross the threshold, then keep spreading — still one toggle.
      await g1.moveBy(const Offset(-40, 0));
      await g2.moveBy(const Offset(40, 0));
      await tester.pump();
      await g1.moveBy(const Offset(-40, 0));
      await g2.moveBy(const Offset(40, 0));
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pump();
      expect(toggles, 1);
    });

    testWidgets('pinch-in inline stays minimized (no toggle)', (tester) async {
      var toggles = 0;
      await tester.pumpWidget(build(onToggleFullscreen: () => toggles++));
      await tester.pump();

      // Fingers 140px apart closing to 40px (scale ~0.29 < exit threshold).
      await pinch(
        tester,
        startA: const Offset(-70, 0),
        startB: const Offset(70, 0),
        moveA: const Offset(50, 0),
        moveB: const Offset(-50, 0),
      );
      expect(toggles, 0);
    });

    testWidgets('pinch-in fullscreen exits fullscreen', (tester) async {
      var toggles = 0;
      await tester.pumpWidget(build(
        isFullscreen: true,
        onToggleFullscreen: () => toggles++,
      ));
      await tester.pump();

      await pinch(
        tester,
        startA: const Offset(-70, 0),
        startB: const Offset(70, 0),
        moveA: const Offset(50, 0),
        moveB: const Offset(-50, 0),
      );
      expect(toggles, 1);
    });

    testWidgets('pinch-out fullscreen does nothing (already fullscreen)',
        (tester) async {
      var toggles = 0;
      await tester.pumpWidget(build(
        isFullscreen: true,
        onToggleFullscreen: () => toggles++,
      ));
      await tester.pump();

      await pinch(
        tester,
        startA: const Offset(-30, 0),
        startB: const Offset(30, 0),
        moveA: const Offset(-60, 0),
        moveB: const Offset(60, 0),
      );
      expect(toggles, 0);
    });

    testWidgets('tap-to-toggle controls still works after a pinch',
        (tester) async {
      await tester.pumpWidget(build(
        initialPlaying: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();
      await tester
          .pump(kInlineControlsAutoHideDelay + const Duration(seconds: 1));
      expect(controlsOpacity(tester), 0.0);

      // A pinch must not break the surface tap handling.
      await pinch(
        tester,
        startA: const Offset(-70, 0),
        startB: const Offset(70, 0),
        moveA: const Offset(50, 0),
        moveB: const Offset(-50, 0),
      );
      await tester.tapAt(tester.getCenter(find.byType(VideoOverlayControls)));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);
    });

    testWidgets('double-tap on the right half seeks +10s (VOD only)',
        (tester) async {
      Duration? seeked;
      await tester.pumpWidget(build(
        isLive: false,
        onSeek: (d) => seeked = d,
        initialPosition: const Duration(seconds: 30),
        initialDuration: const Duration(minutes: 1),
      ));
      await tester.pump();

      final finder = find.byType(VideoOverlayControls);
      final topLeft = tester.getTopLeft(finder);
      final size = tester.getSize(finder);
      final rightHalf = topLeft + Offset(size.width * 0.75, size.height * 0.5);

      await tester.tapAt(rightHalf);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(rightHalf);
      await tester.pump(const Duration(milliseconds: 60));

      expect(seeked, const Duration(seconds: 40));
    });

    // ── Inline 20s inactivity auto-hide ─────────────────────────────────────

    /// Whether the controls layer is currently non-hittable (faded out).
    bool controlsIgnored(WidgetTester tester) {
      final ignorePointer = tester.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byKey(const ValueKey('video-overlay-controls')),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      return ignorePointer.ignoring;
    }

    /// An inline VOD overlay with a scrubber and a fullscreen button — i.e.
    /// everything the inactivity fade covers.
    Widget inlineVod({bool playing = true}) => build(
          initialPlaying: playing,
          onSeek: (_) {},
          initialDuration: const Duration(minutes: 10),
          onToggleFullscreen: () {},
        );

    testWidgets(
        'inline: paused controls never auto-hide, even long past 20s',
        (tester) async {
      await tester.pumpWidget(inlineVod(playing: false));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);

      await tester.pump(const Duration(seconds: 25));
      expect(controlsOpacity(tester), 1.0);
      expect(controlsIgnored(tester), isFalse);
      // The scrubber and the corner button are still on screen and hittable.
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    });

    testWidgets(
        'inline: playing controls survive 19s of inactivity and fade at 20s',
        (tester) async {
      await tester.pumpWidget(inlineVod());
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);

      // Just before the boundary — the scrubber and buttons are still there.
      await tester.pump(const Duration(seconds: 19));
      expect(controlsOpacity(tester), 1.0);
      expect(controlsIgnored(tester), isFalse);

      // Past the boundary — faded out and no longer hittable.
      await tester.pump(const Duration(seconds: 2));
      expect(controlsOpacity(tester), 0.0);
      expect(controlsIgnored(tester), isTrue);
    });

    testWidgets('inline: a tap reveals the controls and restarts the 20s timer',
        (tester) async {
      await tester.pumpWidget(inlineVod());
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      expect(controlsOpacity(tester), 0.0);

      // Tap the surface: back on, hittable, and the countdown starts over.
      // The extra pump lets the double-tap recognizer (VOD ±10s) time out so
      // the single tap resolves.
      await tester.tapAt(tester.getCenter(find.byType(VideoOverlayControls)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(controlsOpacity(tester), 1.0);
      expect(controlsIgnored(tester), isFalse);

      await tester.pump(const Duration(seconds: 19));
      expect(controlsOpacity(tester), 1.0,
          reason: 'the tap must have restarted the full 20s window');
      await tester.pump(const Duration(seconds: 2));
      expect(controlsOpacity(tester), 0.0);
    });

    testWidgets(
        'inline: pressing the fullscreen button restarts the 20s timer',
        (tester) async {
      var toggles = 0;
      await tester.pumpWidget(build(
        initialPlaying: true,
        onSeek: (_) {},
        initialDuration: const Duration(minutes: 10),
        onToggleFullscreen: () => toggles++,
      ));
      await tester.pump();

      // 15s in — still visible; pressing fullscreen resets the countdown.
      await tester.pump(const Duration(seconds: 15));
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      // Let the surface's double-tap recognizer time out so the button's tap
      // wins the gesture arena.
      await tester.pump(const Duration(milliseconds: 400));
      expect(toggles, 1);

      // 15s after the press (30s after mount) the controls are still up.
      await tester.pump(const Duration(seconds: 15));
      expect(controlsOpacity(tester), 1.0);
      await tester.pump(const Duration(seconds: 6));
      expect(controlsOpacity(tester), 0.0);
    });

    testWidgets('inline: scrubbing the seek bar restarts the 20s timer',
        (tester) async {
      Duration? seeked;
      await tester.pumpWidget(build(
        initialPlaying: true,
        onSeek: (d) => seeked = d,
        initialDuration: const Duration(minutes: 10),
        onToggleFullscreen: () {},
      ));
      await tester.pump();

      await tester.pump(const Duration(seconds: 15));
      await tester.drag(find.byType(Slider), const Offset(40, 0));
      await tester.pump();
      expect(seeked, isNotNull);

      await tester.pump(const Duration(seconds: 15));
      expect(controlsOpacity(tester), 1.0);
      await tester.pump(const Duration(seconds: 6));
      expect(controlsOpacity(tester), 0.0);
    });

    testWidgets(
        'inline: hidden controls are not hittable — a tap on the fullscreen '
        'corner only reveals them', (tester) async {
      var toggles = 0;
      await tester.pumpWidget(build(
        initialPlaying: true,
        onSeek: (_) {},
        initialDuration: const Duration(minutes: 10),
        onToggleFullscreen: () => toggles++,
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      expect(controlsIgnored(tester), isTrue);

      // Tapping where the fullscreen button sits must NOT trigger it while the
      // controls are faded out; it just brings them back.
      await tester.tap(find.byIcon(Icons.fullscreen_rounded),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(toggles, 0);
      expect(controlsOpacity(tester), 1.0);
    });

    testWidgets('fullscreen keeps its own, shorter auto-hide window',
        (tester) async {
      await tester.pumpWidget(build(
        initialPlaying: true,
        isFullscreen: true,
        onToggleFullscreen: () {},
      ));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);
      await tester.pump(kFullscreenControlsAutoHideDelay -
          const Duration(seconds: 1));
      expect(controlsOpacity(tester), 1.0);
      await tester.pump(const Duration(seconds: 2));
      expect(controlsOpacity(tester), 0.0);
    });

    testWidgets('double-tap does nothing on a live stream', (tester) async {
      Duration? seeked;
      await tester.pumpWidget(build(
        isLive: true,
        onSeek: (d) => seeked = d,
      ));
      await tester.pump();

      final finder = find.byType(VideoOverlayControls);
      final center = tester.getCenter(finder);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));

      expect(seeked, isNull);
    });
  });
}
