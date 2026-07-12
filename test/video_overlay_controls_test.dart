import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
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
      expect(
          formatOverlayTime(const Duration(minutes: 3, seconds: 7)), '3:07');
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
    test('play control is 56 and skip controls are the smaller 36', () {
      expect(kOverlayPlayButtonSize, 56.0);
      expect(kOverlaySkipButtonSize, 36.0);
      // Skip controls must read as clearly secondary to play.
      expect(kOverlaySkipButtonSize, lessThan(kOverlayPlayButtonSize));
      expect(kOverlaySkipButtonSize, lessThanOrEqualTo(36.0));
    });
  });

  group('distinctVideoQualities', () {
    VideoTrack track(String id, {int? h, int? w}) =>
        VideoTrack(id, null, null, w: w, h: h);

    test('drops auto/no and tracks without a height', () {
      final result = distinctVideoQualities([
        VideoTrack.auto(),
        VideoTrack.no(),
        track('a'), // no height
        track('b', h: 720, w: 1280),
      ]);
      expect(result.map((q) => q.label), ['720p']);
    });

    test('de-dupes by height and sorts highest first', () {
      final result = distinctVideoQualities([
        track('a', h: 720, w: 1280),
        track('b', h: 1080, w: 1920),
        track('c', h: 720, w: 1280), // duplicate height
        track('d', h: 480, w: 854),
      ]);
      expect(result.map((q) => q.label), ['1080p', '720p', '480p']);
      // Kept the first track seen per height.
      expect(result.firstWhere((q) => q.label == '720p').track.id, 'a');
    });

    test('empty when no real qualities exist', () {
      expect(distinctVideoQualities([VideoTrack.auto(), VideoTrack.no()]),
          isEmpty);
    });
  });

  group('VideoOverlayControls widget', () {
    late StreamController<bool> playing;
    late StreamController<bool> buffering;
    late StreamController<Duration> position;
    late StreamController<Duration> duration;

    setUp(() {
      playing = StreamController<bool>.broadcast();
      buffering = StreamController<bool>.broadcast();
      position = StreamController<Duration>.broadcast();
      duration = StreamController<Duration>.broadcast();
    });

    tearDown(() {
      playing.close();
      buffering.close();
      position.close();
      duration.close();
    });

    Widget build({
      bool initialPlaying = false,
      bool initialBuffering = false,
      bool isLive = false,
      bool showTransport = false,
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
                showTransport: showTransport,
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

      // Well past the 3s auto-hide window — still visible while paused.
      await tester.pump(const Duration(seconds: 4));
      expect(controlsOpacity(tester), 1.0);
    });

    testWidgets('playing controls auto-hide after ~3s, tap brings them back',
        (tester) async {
      await tester.pumpWidget(build(initialPlaying: true));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);

      await tester.pump(const Duration(seconds: 4));
      expect(controlsOpacity(tester), 0.0);

      // Any tap on the (now pass-through) surface toggles controls back on.
      await tester.tapAt(tester.getCenter(find.byType(VideoOverlayControls)));
      await tester.pump();
      expect(controlsOpacity(tester), 1.0);
    });

    testWidgets('buffering shows a single spinner in the play button, '
        'controls stay visible', (tester) async {
      await tester.pumpWidget(build(initialBuffering: true));
      await tester.pump();
      // Exactly one spinner (in the play/pause button), not a separate center
      // spinner plus a transport spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Controls remain visible while buffering (no longer hidden).
      expect(controlsOpacity(tester), 1.0);
      // The play/pause glyph is replaced by the spinner while buffering.
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
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

    testWidgets('fallbackDuration enables the seek bar before the player '
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

    testWidgets('prev/next appear only when showTransport is true',
        (tester) async {
      await tester.pumpWidget(build(showTransport: false));
      await tester.pump();
      expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);
      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);

      await tester.pumpWidget(build(showTransport: true));
      await tester.pump();
      expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
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
      final rightHalf =
          topLeft + Offset(size.width * 0.75, size.height * 0.5);

      await tester.tapAt(rightHalf);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(rightHalf);
      await tester.pump(const Duration(milliseconds: 60));

      expect(seeked, const Duration(seconds: 40));
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
