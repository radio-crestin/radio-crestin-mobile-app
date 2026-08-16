import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/video_overlay_controls.dart';
import 'package:radio_crestin/widgets/youtube_iframe_player.dart';

/// Regression tests for the inline YouTube controls layer.
///
/// BUG: `_YoutubeIframePlayerState._onFullscreenChanged` mutated the
/// `_isFullscreen` flag WITHOUT `setState`, even though `build` gates the
/// inline [VideoOverlayControls] on it. Entering fullscreen therefore left our
/// controls layer drawn over YouTube's own fullscreen chrome until some
/// unrelated rebuild happened to come along — two competing control layers,
/// non-deterministically.
///
/// FIX: the flag flips inside `setState` (mounted-guarded), and the gating
/// itself moved into [InlineYoutubeOverlay] so this contract is pinned here
/// without needing a live WebView: fullscreen REMOVES the overlay from the
/// tree, exiting fullscreen puts it back.

/// Mirrors the production surface: a [Stack] with a stand-in for the iframe and
/// the gated overlay on top, whose fullscreen flag flips via `setState` exactly
/// as the fixed `_onFullscreenChanged` does.
class _FullscreenHost extends StatefulWidget {
  const _FullscreenHost({super.key, required this.overlay});

  final Widget overlay;

  @override
  State<_FullscreenHost> createState() => _FullscreenHostState();
}

class _FullscreenHostState extends State<_FullscreenHost> {
  bool fullscreen = false;

  void setFullscreen(bool value) => setState(() => fullscreen = value);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const SizedBox(width: 320, height: 180, key: Key('iframe')),
        InlineYoutubeOverlay(fullscreen: fullscreen, child: widget.overlay),
      ],
    );
  }
}

Widget _overlay({
  required StreamController<bool> playing,
  required StreamController<Duration> position,
}) {
  return VideoOverlayControls(
    playingStream: playing.stream,
    bufferingStream: const Stream<bool>.empty(),
    positionStream: position.stream,
    durationStream: const Stream<Duration>.empty(),
    initialDuration: const Duration(minutes: 3),
    title: 'Inline item',
    onPlay: () {},
    onPause: () {},
    onSeek: (_) {},
    onToggleFullscreen: () {},
  );
}

void main() {
  late StreamController<bool> playing;
  late StreamController<Duration> position;

  setUp(() {
    playing = StreamController<bool>.broadcast();
    position = StreamController<Duration>.broadcast();
  });

  tearDown(() async {
    await playing.close();
    await position.close();
  });

  group('InlineYoutubeOverlay gating', () {
    testWidgets('inline: the controls layer fills the surface', (tester) async {
      // Arrange + Act.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            InlineYoutubeOverlay(
              fullscreen: false,
              child: _overlay(playing: playing, position: position),
            ),
          ]),
        ),
      ));

      // Assert: present, and positioned to fill its Stack parent.
      expect(find.byType(VideoOverlayControls), findsOneWidget);
      final positioned = tester.widget<Positioned>(find.descendant(
        of: find.byType(InlineYoutubeOverlay),
        matching: find.byType(Positioned),
      ));
      expect(positioned.left, 0);
      expect(positioned.top, 0);
      expect(positioned.right, 0);
      expect(positioned.bottom, 0);
    });

    testWidgets('fullscreen: the controls layer is absent from the tree',
        (tester) async {
      // Arrange + Act.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            InlineYoutubeOverlay(
              fullscreen: true,
              child: _overlay(playing: playing, position: position),
            ),
          ]),
        ),
      ));

      // Assert: gone entirely — not merely invisible (an invisible layer would
      // still swallow taps meant for YouTube's own chrome).
      expect(find.byType(VideoOverlayControls), findsNothing);
      expect(
        find.descendant(
          of: find.byType(InlineYoutubeOverlay),
          matching: find.byType(Positioned),
        ),
        findsNothing,
      );
    });
  });

  group('fullscreen transitions rebuild the surface (the regression)', () {
    testWidgets('entering fullscreen REMOVES the inline overlay, exiting '
        'restores it', (tester) async {
      // Arrange: the inline surface, overlay visible.
      final key = GlobalKey<_FullscreenHostState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: _FullscreenHost(
            key: key,
            overlay: _overlay(playing: playing, position: position),
          ),
        ),
      ));
      expect(find.byType(VideoOverlayControls), findsOneWidget);

      // Act: the player reports it entered fullscreen.
      key.currentState!.setFullscreen(true);
      await tester.pump();

      // Assert: the overlay is gone on the very next frame — no extra,
      // unrelated rebuild needed (that was the bug).
      expect(find.byType(VideoOverlayControls), findsNothing);
      expect(find.byKey(const Key('iframe')), findsOneWidget);

      // Act: back out of fullscreen.
      key.currentState!.setFullscreen(false);
      await tester.pump();

      // Assert: the inline controls are back.
      expect(find.byType(VideoOverlayControls), findsOneWidget);
    });

    testWidgets('the iframe stand-in survives both transitions (no remount)',
        (tester) async {
      // Arrange.
      final key = GlobalKey<_FullscreenHostState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: _FullscreenHost(
            key: key,
            overlay: _overlay(playing: playing, position: position),
          ),
        ),
      ));
      final element = tester.element(find.byKey(const Key('iframe')));

      // Act.
      key.currentState!.setFullscreen(true);
      await tester.pump();
      key.currentState!.setFullscreen(false);
      await tester.pump();

      // Assert: the player element is the SAME one — dropping the overlay must
      // never tear down the iframe (that would interrupt playback).
      expect(tester.element(find.byKey(const Key('iframe'))), same(element));
    });
  });
}
