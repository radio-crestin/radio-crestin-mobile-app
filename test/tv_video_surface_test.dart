import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/tv/widgets/tv_video_surface.dart';
import 'package:video_player/video_player.dart';

import 'helpers/fake_video_player_platform.dart';

/// Widget tests for [TvVideoSurface]'s loading feedback.
///
/// The TV/desktop surface must never be a plain black rectangle while a channel
/// is opening: between "no controller yet" and the first frame the engine
/// reports nothing, so the surface itself has to show the spinner. It stands
/// down as soon as there is an initialized, non-buffering picture.
void main() {
  late FakeVideoPlayerPlatform platform;
  late VideoPlaybackService service;

  setUp(() {
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    service = VideoPlaybackService();
  });

  tearDown(() async {
    await service.dispose();
    await platform.shutdown();
  });

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 640, height: 360, child: child)),
      );

  testWidgets('shows a spinner while no controller exists yet', (tester) async {
    // Arrange + Act: the media has not been opened (or is still opening).
    await tester.pumpWidget(host(TvVideoSurface(videoService: service)));

    // Assert: the user sees progress, not a black box.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final spinner = tester
        .widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
    expect(spinner.strokeWidth, 2.5);
  });

  testWidgets('stands down once an initialized picture is playing',
      (tester) async {
    // Arrange: a media that initializes with real dimensions.
    const url = 'https://example.com/tv.m3u8';
    platform.script(url, const FakeMediaScript());
    await tester.runAsync(() async {
      await service.open(url, autoPlay: false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    // Act.
    await tester.pumpWidget(host(TvVideoSurface(videoService: service)));
    await tester.pumpAndSettle();

    // Assert.
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
