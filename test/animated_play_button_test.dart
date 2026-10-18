import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/widgets/animated_play_button.dart';

void main() {
  group('AnimatedPlayButton', () {
    late StreamController<PlaybackState> playbackController;

    setUp(() {
      playbackController = StreamController<PlaybackState>.broadcast();
    });

    tearDown(() {
      playbackController.close();
    });

    Widget buildWidget({
      VoidCallback? onPlay,
      VoidCallback? onPause,
      double iconSize = 48,
      Color? backgroundColor,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: AnimatedPlayButton(
            playbackStateStream: playbackController.stream,
            iconSize: iconSize,
            iconColor: Colors.white,
            backgroundColor: backgroundColor,
            onPlay: onPlay ?? () {},
            onPause: onPause ?? () {},
          ),
        ),
      );
    }

    testWidgets('shows play icon initially', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    });

    testWidgets('shows pause icon when stream says playing', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      playbackController.add(PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
      ));
      await tester.pump();

      // After grace period expires, stream truth wins
      await tester.pump(const Duration(seconds: 4));
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });

    testWidgets('calls onPlay when tapped while showing play icon', (tester) async {
      var playCalled = false;
      await tester.pumpWidget(buildWidget(onPlay: () => playCalled = true));
      await tester.pump();

      await tester.tap(find.byType(InkWell));
      expect(playCalled, true);
    });

    testWidgets('calls onPause when tapped while showing pause icon', (tester) async {
      var pauseCalled = false;
      await tester.pumpWidget(buildWidget(onPause: () => pauseCalled = true));
      await tester.pump();

      // First tap sets intent to playing
      await tester.tap(find.byType(InkWell));
      await tester.pump();

      // Now it shows pause, tap again
      await tester.tap(find.byType(InkWell));
      expect(pauseCalled, true);
    });

    testWidgets('shows optimistic play state during grace period', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      // Tap to set intent = playing
      await tester.tap(find.byType(InkWell));
      await tester.pump();

      // During grace period, should show pause (optimistic)
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    });

    testWidgets('settled stream state immediately syncs intent', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      // Tap to set intent = playing
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      // Stream settles to NOT playing + ready → immediately syncs intent
      playbackController.add(PlaybackState(
        playing: false,
        processingState: AudioProcessingState.ready,
      ));
      await tester.pump();

      // Intent is now synced to stream reality (play icon)
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('shows loading spinner when buffering during playback', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      // Emit loading state (triggers _streamLoading = true)
      playbackController.add(PlaybackState(
        playing: true,
        processingState: AudioProcessingState.loading,
      ));
      // Use pump() not pumpAndSettle() — CircularProgressIndicator animates indefinitely
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Spinner shows when stream is loading
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('keeps the spinner while the car waits for the internet',
        (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      // AppAudioHandler.setOfflineError: still trying to play.
      playbackController.add(PlaybackState(
        playing: true,
        processingState: AudioProcessingState.error,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('tapping spinner cancels in-flight play via onPause', (tester) async {
      // A stuck buffering state must not stop the player, which left the
      // button unresponsive after skip-next. See AnimatedPlayButton.build().
      var pauseCalled = false;
      await tester.pumpWidget(buildWidget(
        onPause: () => pauseCalled = true,
      ));
      await tester.pump();

      playbackController.add(PlaybackState(
        playing: true,
        processingState: AudioProcessingState.loading,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byType(InkWell));
      expect(pauseCalled, true);
    });

    testWidgets('renders with background color when provided', (tester) async {
      await tester.pumpWidget(buildWidget(backgroundColor: Colors.blue));
      await tester.pump();

      expect(find.byType(ClipOval), findsOneWidget);
    });

    testWidgets('renders without background color by default', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      expect(find.byType(ClipOval), findsNothing);
    });

    testWidgets('swaps the icon at once, without a fade', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      await tester.tap(find.byType(InkWell));
      await tester.pump();

      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('re-broadcast with no visible change schedules no frame',
        (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      final playing = PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
      );
      playbackController.add(playing);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);

      // Live streams re-broadcast on every buffered-position tick.
      playbackController.add(playing.copyWith(
        bufferedPosition: const Duration(seconds: 5),
      ));
      await tester.idle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      // A real change still rebuilds.
      playbackController.add(playing.copyWith(
        processingState: AudioProcessingState.loading,
      ));
      await tester.idle();
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    group('spinner timing', () {
      PlaybackState state(AudioProcessingState processing,
              {bool playing = true}) =>
          PlaybackState(playing: playing, processingState: processing);

      // Delivers [s] to the button, then lets [elapse] pass and renders.
      Future<void> emit(WidgetTester tester, PlaybackState s,
          [Duration elapse = Duration.zero]) async {
        playbackController.add(s);
        await tester.idle();
        await tester.pump(elapse);
      }

      testWidgets('shows the pause icon as soon as a loaded station plays',
          (tester) async {
        await tester.pumpWidget(buildWidget());
        await tester.pump();

        // What AppAudioHandler reports on an iPhone at a station switch:
        // AVPlayer buffers ~120 ms after play() before audio comes out.
        await emit(tester, state(AudioProcessingState.loading));
        await emit(tester, state(AudioProcessingState.buffering),
            const Duration(milliseconds: 120));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byIcon(Icons.pause_rounded), findsNothing);

        await emit(tester, state(AudioProcessingState.ready));
        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      });

      testWidgets('shows no spinner for the short buffering of a resume',
          (tester) async {
        await tester.pumpWidget(buildWidget());
        await tester.pump();

        await tester.tap(find.byType(InkWell));
        await emit(tester, state(AudioProcessingState.ready),
            const Duration(milliseconds: 20));
        await emit(tester, state(AudioProcessingState.buffering),
            const Duration(milliseconds: 50));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await emit(tester, state(AudioProcessingState.ready),
            const Duration(milliseconds: 500));

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      });

      testWidgets('shows the spinner once buffering lasts', (tester) async {
        await tester.pumpWidget(buildWidget());
        await tester.pump();

        await emit(tester, state(AudioProcessingState.ready));
        await emit(tester, state(AudioProcessingState.buffering),
            const Duration(milliseconds: 150));
        expect(find.byType(CircularProgressIndicator), findsNothing);

        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      });

      testWidgets('drops the spinner at once for a pause', (tester) async {
        await tester.pumpWidget(buildWidget());
        await tester.pump();

        await emit(tester, state(AudioProcessingState.loading));
        await emit(tester, state(AudioProcessingState.ready, playing: false));

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      });
    });

    testWidgets('settled event clears an active grace period', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      // Optimistic play; stream then reports not-playing + idle, which
      // matches the stored stream flags but must still drop the intent.
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      playbackController.add(PlaybackState(
        playing: false,
        processingState: AudioProcessingState.idle,
      ));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('disposes cleanly without errors', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      // Replace widget to trigger dispose
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pump();
      // No errors = success
    });
  });
}
