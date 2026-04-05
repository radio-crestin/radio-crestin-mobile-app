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
      VoidCallback? onStop,
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
            onStop: onStop ?? () {},
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

    testWidgets('tapping spinner calls onStop', (tester) async {
      var stopCalled = false;
      await tester.pumpWidget(buildWidget(onStop: () => stopCalled = true));
      await tester.pump();

      // Emit loading state
      playbackController.add(PlaybackState(
        playing: true,
        processingState: AudioProcessingState.loading,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Tap the spinner
      await tester.tap(find.byType(InkWell));
      expect(stopCalled, true);
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

    testWidgets('AnimatedSwitcher is present for smooth transitions', (tester) async {
      await tester.pumpWidget(buildWidget());
      await tester.pump();

      expect(find.byType(AnimatedSwitcher), findsOneWidget);
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
