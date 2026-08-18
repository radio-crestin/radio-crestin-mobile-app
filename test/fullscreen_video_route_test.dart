import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/widgets/video_overlay_controls.dart';

import 'helpers/fake_video_player_platform.dart';

/// Tests for the fullscreen route [VideoPlayerStage] pushes.
///
/// The behaviour that matters here is what happens when playback leaves video
/// while the user is fullscreen — skipping from a TV channel to a radio
/// station. The route must STAY, swapping its body for the caller's audio face,
/// because ejecting the user back to the station list would punish them for
/// using the skip button. It must also never build a second video engine.
void main() {
  late FakeVideoPlayerPlatform platform;
  late VideoPlaybackService service;
  late StreamController<bool> hasVideo;

  setUp(() {
    // Entering fullscreen awaits SystemChrome; without a stub for
    // `flutter/platform` that await never returns under the test binding's
    // fake clock and the route is never pushed.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SystemChannels.platform, (call) async => null);
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    service = VideoPlaybackService();
    hasVideo = StreamController<bool>.broadcast();
  });

  tearDown(() async {
    await hasVideo.close();
    await service.dispose();
    await platform.shutdown();
  });

  /// Pumps a stage whose fullscreen route can fall back to a marked audio face.
  Future<void> pumpStage(
    WidgetTester tester, {
    bool withAudioFace = true,
    bool initialHasVideo = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: VideoPlayerStage(
              videoService: service,
              title: 'Canal TV',
              isLive: true,
              onPlay: () {},
              onPause: () {},
              onPrevious: () {},
              onNext: () {},
              hasVideoStream: hasVideo.stream,
              initialHasVideo: initialHasVideo,
              // Stands in for FullscreenAudioStage, which carries the same
              // overlay transport (including the exit control) over the
              // station artwork.
              fullscreenAudioBuilder: withAudioFace
                  ? (context, exit) => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('audio-face',
                                key: ValueKey('audio-face')),
                            IconButton(
                              icon: const Icon(Icons.fullscreen_exit_rounded),
                              onPressed: exit,
                            ),
                          ],
                        ),
                      )
                  : null,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Advances a few frames past the route transition and the overlay fades.
  ///
  /// `pumpAndSettle` is unusable here: an opening surface shows a
  /// CircularProgressIndicator, which never stops animating.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Taps the inline corner control to push the fullscreen route.
  Future<void> enterFullscreen(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await settle(tester);
  }

  testWidgets('entering fullscreen shows the video body and an exit control',
      (tester) async {
    // Arrange + Act.
    await pumpStage(tester);
    await enterFullscreen(tester);

    // Assert.
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-face')), findsNothing);
  });

  testWidgets('losing video swaps to the audio face without leaving fullscreen',
      (tester) async {
    // Arrange.
    await pumpStage(tester);
    await enterFullscreen(tester);

    // Act: the user skipped from a TV channel onto a radio station.
    hasVideo.add(false);
    await settle(tester);

    // Assert: still fullscreen, now showing what a radio station has to show.
    expect(find.byKey(const ValueKey('audio-face')), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
  });

  testWidgets('coming back to video restores the video body', (tester) async {
    // Arrange.
    await pumpStage(tester);
    await enterFullscreen(tester);
    hasVideo.add(false);
    await settle(tester);
    expect(find.byKey(const ValueKey('audio-face')), findsOneWidget);

    // Act: the next skip lands on another TV channel.
    hasVideo.add(true);
    await settle(tester);

    // Assert.
    expect(find.byKey(const ValueKey('audio-face')), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
  });

  testWidgets('the exit control still pops the route from the audio face',
      (tester) async {
    // Arrange.
    await pumpStage(tester);
    await enterFullscreen(tester);
    hasVideo.add(false);
    await settle(tester);

    // Act.
    await tester.tap(find.byIcon(Icons.fullscreen_exit_rounded));
    await settle(tester);

    // Assert: back to the inline surface.
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-face')), findsNothing);
  });

  testWidgets('without an audio face the route keeps the video body',
      (tester) async {
    // Arrange: callers that have nothing to show for audio keep the old
    // behaviour rather than a blank screen.
    await pumpStage(tester, withAudioFace: false);
    await enterFullscreen(tester);

    // Act.
    hasVideo.add(false);
    await settle(tester);

    // Assert.
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
  });

  testWidgets('the route never creates a second video engine', (tester) async {
    // Arrange: one media open before fullscreen.
    // A non-playlist URL, so the (real, network-bound) quality probe is never
    // even attempted from inside the test.
    const url = 'https://example.test/live.mp4';
    await tester.runAsync(() => service.open(url, live: true, autoPlay: false));
    await tester.pump();
    final createdBefore = platform.created.length;

    // Act.
    await pumpStage(tester);
    await enterFullscreen(tester);
    hasVideo.add(false);
    await settle(tester);
    hasVideo.add(true);
    await settle(tester);

    // Assert: the single-engine invariant — every surface renders the SAME
    // controller, and fullscreen is just another view of it.
    expect(platform.created.length, createdBefore);
  });
}
