import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/live_duration_video_platform.dart';

import 'helpers/fake_video_player_platform.dart';

/// Unit tests for [LiveDurationVideoPlatform] — the decorator that rewrites the
/// indefinite-duration artefact out of the platform event stream.
///
/// The whole point of doing this BELOW `VideoPlayerController` is that the
/// controller derives `isCompleted`, the position clamp and the rewind-on-play
/// from the duration it is handed, and none of that is reachable from Dart.
/// These tests therefore assert on what the decorator hands upward, and on the
/// record it keeps so the app can still tell a live stream from an on-demand
/// one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVideoPlayerPlatform fake;

  setUp(() {
    fake = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fake;
  });

  tearDown(() async {
    await fake.shutdown();
  });

  /// Creates a player for [url] through the installed platform and returns its
  /// id (the decorator forwards creation to the fake).
  Future<int> createPlayer(String url) async {
    final id = await VideoPlayerPlatform.instance.createWithOptions(
      VideoCreationOptions(
        dataSource: DataSource(
          sourceType: DataSourceType.network,
          uri: url,
        ),
        viewType: VideoViewType.textureView,
      ),
    );
    return id!;
  }

  /// Drains the first event the decorator emits for [playerId] while the fake
  /// reports [duration].
  Future<VideoEvent> firstEvent(int playerId, Duration? duration) {
    final future = VideoPlayerPlatform.instance.videoEventsFor(playerId).first;
    fake.emit(
      playerId,
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: duration,
        size: const Size(1280, 720),
      ),
    );
    return future;
  }

  group('installation', () {
    test('ensureInstalled wraps the current platform exactly once', () {
      // Act.
      LiveDurationVideoPlatform.ensureInstalled();
      final installed = VideoPlayerPlatform.instance;
      LiveDurationVideoPlatform.ensureInstalled();

      // Assert: idempotent — a second call must not stack a second decorator.
      expect(installed, isA<LiveDurationVideoPlatform>());
      expect(identical(VideoPlayerPlatform.instance, installed), isTrue);
      expect((installed as LiveDurationVideoPlatform).delegate, same(fake));
    });

    test('every call forwards to the wrapped platform', () async {
      // Arrange.
      LiveDurationVideoPlatform.ensureInstalled();
      final id = await createPlayer('https://example.test/a.m3u8');

      // Act.
      await VideoPlayerPlatform.instance.play(id);
      await VideoPlayerPlatform.instance.pause(id);
      await VideoPlayerPlatform.instance.setVolume(id, 0.5);
      await VideoPlayerPlatform.instance.seekTo(id, const Duration(minutes: 1));

      // Assert.
      expect(fake.played, contains(id));
      expect(fake.paused, contains(id));
      expect(fake.volumesFor(id), [0.5]);
      expect(fake.seeksFor(id), [const Duration(minutes: 1)]);
    });
  });

  group('duration rewriting', () {
    setUp(LiveDurationVideoPlatform.ensureInstalled);

    test('the 1ms overflow artefact becomes an unreachable stand-in', () async {
      // Arrange.
      const url = 'https://example.test/live.m3u8';
      final id = await createPlayer(url);

      // Act.
      final event = await firstEvent(id, kIndefiniteDurationSentinel);

      // Assert: with a length nothing can reach, VideoPlayerController cannot
      // clamp the playhead, latch isCompleted, or rewind on play().
      expect(event.duration, kIndefiniteDurationStandIn);
      expect(isPlausibleMediaDuration(event.duration), isFalse);
      expect(LiveDurationVideoPlatform.isIndefinite(id), isTrue);
      expect(LiveDurationVideoPlatform.isIndefiniteUrl(url), isTrue);
    });

    test('a zero or negative length is the same artefact', () async {
      // Arrange.
      final zeroId = await createPlayer('https://example.test/zero.m3u8');
      final negativeId = await createPlayer('https://example.test/neg.m3u8');

      // Act.
      final zero = await firstEvent(zeroId, Duration.zero);
      final negative =
          await firstEvent(negativeId, const Duration(seconds: -5));

      // Assert.
      expect(zero.duration, kIndefiniteDurationStandIn);
      expect(negative.duration, kIndefiniteDurationStandIn);
    });

    test('a real media length passes through untouched', () async {
      // Arrange.
      const url = 'https://example.test/clip.mp4';
      final id = await createPlayer(url);

      // Act.
      final event = await firstEvent(id, const Duration(minutes: 3));

      // Assert.
      expect(event.duration, const Duration(minutes: 3));
      expect(LiveDurationVideoPlatform.isIndefinite(id), isFalse);
      expect(LiveDurationVideoPlatform.isIndefiniteUrl(url), isFalse);
    });

    test('a null length is left alone', () async {
      // Arrange: video_player reads `isInitialized: event.duration != null`, so
      // inventing a length here would declare a dead player ready to render.
      final id = await createPlayer('https://example.test/broken.m3u8');

      // Act.
      final event = await firstEvent(id, null);

      // Assert.
      expect(event.duration, isNull);
      expect(LiveDurationVideoPlatform.isIndefinite(id), isFalse);
    });

    test('non-initialized events are forwarded verbatim', () async {
      // Arrange.
      final id = await createPlayer('https://example.test/live.m3u8');
      final future = VideoPlayerPlatform.instance.videoEventsFor(id).first;

      // Act.
      fake.emit(id, VideoEvent(eventType: VideoEventType.bufferingStart));
      final event = await future;

      // Assert.
      expect(event.eventType, VideoEventType.bufferingStart);
      expect(LiveDurationVideoPlatform.isIndefinite(id), isFalse);
    });

    test('disposing a player forgets its record', () async {
      // Arrange.
      const url = 'https://example.test/live.m3u8';
      final id = await createPlayer(url);
      await firstEvent(id, kIndefiniteDurationSentinel);
      expect(LiveDurationVideoPlatform.isIndefiniteUrl(url), isTrue);

      // Act.
      await VideoPlayerPlatform.instance.dispose(id);

      // Assert: a stale "this is live" answer would keep a later on-demand
      // item's scrubber hidden.
      expect(LiveDurationVideoPlatform.isIndefinite(id), isFalse);
      expect(LiveDurationVideoPlatform.isIndefiniteUrl(url), isFalse);
    });
  });

  group('plausibility vocabulary', () {
    test('rejects both the artefact and the stand-in that replaces it', () {
      // Assert.
      expect(isPlausibleMediaDuration(const Duration(minutes: 3)), isTrue);
      expect(isPlausibleMediaDuration(null), isFalse);
      expect(isPlausibleMediaDuration(Duration.zero), isFalse);
      expect(isPlausibleMediaDuration(kIndefiniteDurationSentinel), isFalse);
      expect(isPlausibleMediaDuration(kIndefiniteDurationStandIn), isFalse);
      expect(isPlausibleMediaDuration(kMaxPlausibleMediaDuration), isFalse);
    });

    test('names the reported lengths that mean "indefinite"', () {
      // Assert.
      expect(isIndefiniteReportedDuration(kIndefiniteDurationSentinel), isTrue);
      expect(isIndefiniteReportedDuration(Duration.zero), isTrue);
      expect(isIndefiniteReportedDuration(const Duration(seconds: -1)), isTrue);
      expect(isIndefiniteReportedDuration(const Duration(minutes: 3)), isFalse);
      expect(isIndefiniteReportedDuration(null), isFalse);
    });
  });
}
