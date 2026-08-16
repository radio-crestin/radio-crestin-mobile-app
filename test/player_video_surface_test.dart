import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/widgets/player_video_surface.dart';
import 'package:video_player/video_player.dart';

import 'helpers/fake_video_player_platform.dart';

/// Widget tests for [PlayerVideoSurface] / [VideoRender] — the black canvas
/// that renders whatever controller [VideoPlaybackService] currently owns.
///
/// Two contracts matter here:
///   * the surface renders NOTHING (not a broken/black texture) until there is
///     an initialized controller with real pixel dimensions, and
///   * when a custom [controls] overlay is supplied it owns buffering and the
///     LIVE badge — the built-in spinner and pill must stand down so nothing is
///     drawn twice.
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

  /// Opens [url] on the fake platform and lets the initialize handshake land.
  Future<void> openMedia(
    WidgetTester tester,
    String url, {
    Size size = const Size(1280, 720),
    bool buffering = false,
  }) async {
    platform.script(url, FakeMediaScript(size: size));
    await tester.runAsync(() async {
      await service.open(url, autoPlay: false);
      if (buffering) {
        platform.emit(
          platform.idFor(url),
          VideoEvent(eventType: VideoEventType.bufferingStart),
        );
      }
      // Let the value listeners and the fire-and-forget quality parse settle.
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
  }

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, height: 180, child: child)),
      );

  group('nothing is rendered without a usable picture', () {
    testWidgets('a service that never opened anything renders no video',
        (tester) async {
      // Arrange + Act.
      await tester.pumpWidget(host(PlayerVideoSurface(videoService: service)));

      // Assert: an empty black canvas, no texture, no spinner.
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(VideoRender), findsOneWidget);
    });

    testWidgets('an initialized controller reporting a zero size renders no '
        'video', (tester) async {
      // Arrange: initialized, but the decoder never produced pixels.
      await openMedia(tester, 'https://example.com/nosize.m3u8',
          size: Size.zero);

      // Act.
      await tester.pumpWidget(host(PlayerVideoSurface(videoService: service)));
      await tester.pump();

      // Assert.
      expect(service.isInitialized, isTrue);
      expect(find.byType(VideoPlayer), findsNothing);
    });

    testWidgets('a real size renders the video view', (tester) async {
      // Arrange (the positive control for the two tests above).
      await openMedia(tester, 'https://example.com/sized.m3u8');

      // Act.
      await tester.pumpWidget(host(PlayerVideoSurface(videoService: service)));
      await tester.pump();

      // Assert.
      expect(find.byType(VideoPlayer), findsOneWidget);
    });
  });

  group('built-in spinner + LIVE pill vs a custom controls overlay', () {
    const overlayKey = Key('custom-controls');

    testWidgets('bare surface shows the buffering spinner and the LIVE pill',
        (tester) async {
      // Arrange: a live, buffering stream with no overlay.
      await openMedia(tester, 'https://example.com/live.m3u8',
          buffering: true);

      // Act.
      await tester.pumpWidget(host(PlayerVideoSurface(
        videoService: service,
        showLivePill: true,
      )));
      await tester.pump();

      // Assert.
      expect(service.isBuffering, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LivePill), findsOneWidget);
    });

    testWidgets('with controls the surface draws neither — the overlay owns '
        'them', (tester) async {
      // Arrange: identical state, but an overlay is supplied.
      await openMedia(tester, 'https://example.com/live.m3u8',
          buffering: true);

      // Act.
      await tester.pumpWidget(host(PlayerVideoSurface(
        videoService: service,
        showLivePill: true,
        controls: (_) => const SizedBox.expand(key: overlayKey),
      )));
      await tester.pump();

      // Assert: no double spinner, no double pill.
      expect(service.isBuffering, isTrue);
      expect(find.byKey(overlayKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LivePill), findsNothing);
    });

    testWidgets('the overlay is composed over the video, filling the surface',
        (tester) async {
      // Arrange.
      await openMedia(tester, 'https://example.com/sized.m3u8');

      // Act.
      await tester.pumpWidget(host(PlayerVideoSurface(
        videoService: service,
        controls: (_) => const SizedBox.expand(key: overlayKey),
      )));
      await tester.pump();

      // Assert: both layers present, overlay sized to the whole surface.
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(tester.getSize(find.byKey(overlayKey)), const Size(320, 180));
    });

    testWidgets('a bare, non-buffering surface shows no spinner',
        (tester) async {
      // Arrange.
      await openMedia(tester, 'https://example.com/sized.m3u8');

      // Act.
      await tester.pumpWidget(host(PlayerVideoSurface(videoService: service)));
      await tester.pump();

      // Assert.
      expect(service.isBuffering, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LivePill), findsNothing);
    });
  });
}
