import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/playlist_item.dart';

/// Tests for [PlaylistController.repeatOne] — the transport's repeat button.
///
/// The contract is narrow on purpose: repeat only changes what a NATURAL end of
/// item means (replay this row instead of moving on). Every manual move — the
/// next/previous buttons, the lock screen, a row tap — must still navigate, or
/// the user would be trapped on one track.
///
/// The routing lives in `_advanceOrRepeat`, shared by the audio/video
/// completion callback and by [PlaylistController.notifyYoutubeItemEnded]; the
/// YouTube entry point is the one reachable without a real player, so it is
/// what drives these tests.

/// A stand-in for the real handler: [PlaylistController] reaches it through
/// GetIt on every `playItemAt`, and only these members are on the repeat path.
class _FakeAudioHandler extends Fake implements AppAudioHandler {
  /// Item indexes handed to the handler, in order — i.e. what actually played.
  final List<int> playedIndexes = [];

  bool foreground = true;

  @override
  void resetVideoFallback() {}

  @override
  bool get isVideoModeActive => false;

  @override
  bool get isForeground => foreground;

  @override
  bool get isCarConnected => false;

  @override
  bool get isCasting => false;

  @override
  void updatePlaylistMediaItem(
    PlaylistItem item, {
    required int index,
    required int count,
  }) =>
      playedIndexes.add(index);

  @override
  Future<void> stopPlaylistPlayback() async {}

  @override
  void setPlaylistYoutubeActive(bool active, {bool playing = false}) {}

  @override
  void updateYoutubePlaybackState({bool? playing, Duration? position}) {}

  @override
  Future<void> playPlaylistAudioItem(String url, {Duration? startPosition})
      async {}

  @override
  Future<void> playPlaylistVideoItem(
    String url, {
    bool live = false,
    Duration? startPosition,
  }) async {}
}

PlaylistItem _yt(int id) => PlaylistItem(
      id: id,
      order: id,
      type: PlaylistItemType.youtube,
      url: 'https://youtu.be/vid$id',
      title: 'YT $id',
    );

/// Lets the fire-and-forget `playItemAt` triggered by an advance/repeat run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeAudioHandler handler;
  late PlaylistController controller;

  PlaylistController newController() => PlaylistController(
        videoService: VideoPlaybackService(),
        syncService: PlaylistSyncService(),
      );

  /// Seeds a three-row YouTube playlist positioned on [index].
  void seed(int index) {
    final items = [_yt(1), _yt(2), _yt(3)];
    controller.items.add(items);
    controller.currentIndex.add(index);
    controller.currentItem.add(index >= 0 ? items[index] : items.first);
  }

  setUp(() async {
    handler = _FakeAudioHandler();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<AppAudioHandler>(handler);
    controller = newController();
  });

  tearDown(() async {
    controller.dispose();
    await GetIt.instance.reset();
  });

  group('repeatOne state', () {
    test('starts off and toggles', () {
      // Arrange + Act + Assert.
      expect(controller.repeatOne.value, isFalse);
      controller.toggleRepeatOne();
      expect(controller.repeatOne.value, isTrue);
      controller.toggleRepeatOne();
      expect(controller.repeatOne.value, isFalse);
    });

    test('dispose closes the repeat subject', () {
      // Arrange: a controller of its own so the shared tearDown stays valid.
      final disposable = newController();

      // Act.
      disposable.dispose();

      // Assert: a leaked subject would keep a disposed transport subscribed.
      expect(disposable.repeatOne.isClosed, isTrue);
    });
  });

  group('natural end of item honors repeat', () {
    test('repeat armed → the SAME row is replayed', () async {
      // Arrange: playing row 1 of 3, repeat on.
      seed(1);
      controller.repeatOne.add(true);

      // Act: the inline YouTube player reports the video played through.
      controller.notifyYoutubeItemEnded(itemId: 2);
      await _settle();

      // Assert: replayed in place, never advanced.
      expect(controller.currentIndex.value, 1);
      expect(handler.playedIndexes, [1]);
    });

    test('repeat off → the next row down plays', () async {
      // Arrange: same position, repeat off (the default).
      seed(1);

      // Act.
      controller.notifyYoutubeItemEnded(itemId: 2);
      await _settle();

      // Assert.
      expect(controller.currentIndex.value, 2);
      expect(handler.playedIndexes, [2]);
    });

    test('repeat on the LAST row replays it instead of wrapping to the top',
        () async {
      // Arrange: the tail row — where the difference is most visible.
      seed(2);
      controller.repeatOne.add(true);

      // Act.
      controller.notifyYoutubeItemEnded(itemId: 3);
      await _settle();

      // Assert.
      expect(controller.currentIndex.value, 2);
      expect(handler.playedIndexes, [2]);
    });

    test('without repeat the last row wraps back to the first', () async {
      // Arrange (the control for the test above).
      seed(2);

      // Act.
      controller.notifyYoutubeItemEnded(itemId: 3);
      await _settle();

      // Assert.
      expect(controller.currentIndex.value, 0);
    });

    test('repeat is ignored when nothing is positioned yet', () async {
      // Arrange: repeat armed but no valid index (nothing to replay).
      seed(-1);
      controller.repeatOne.add(true);

      // Act.
      controller.notifyYoutubeItemEnded(itemId: 1);
      await _settle();

      // Assert: falls back to a normal advance rather than replaying nothing.
      expect(controller.currentIndex.value, 0);
    });

    test('a stale callback is still ignored while repeat is armed', () async {
      // Arrange: repeat on, but the event comes from the OUTGOING iframe.
      seed(1);
      controller.repeatOne.add(true);

      // Act.
      controller.notifyYoutubeItemEnded(itemId: 1); // row 0's player
      await _settle();

      // Assert: no replay, no advance — the id guard wins.
      expect(controller.currentIndex.value, 1);
      expect(handler.playedIndexes, isEmpty);
    });
  });

  group('manual navigation ignores repeat', () {
    test('skipToNext still advances while repeat is armed', () async {
      // Arrange.
      seed(1);
      controller.repeatOne.add(true);

      // Act.
      await controller.skipToNext();

      // Assert.
      expect(controller.currentIndex.value, 2);
      expect(handler.playedIndexes, [2]);
    });

    test('skipToPrevious still goes back while repeat is armed', () async {
      // Arrange.
      seed(1);
      controller.repeatOne.add(true);

      // Act.
      await controller.skipToPrevious();

      // Assert.
      expect(controller.currentIndex.value, 0);
      expect(handler.playedIndexes, [0]);
    });

    test('repeat stays armed across a manual skip', () async {
      // Arrange: skipping must not silently disarm the repeat button.
      seed(0);
      controller.repeatOne.add(true);

      // Act.
      await controller.skipToNext();

      // Assert.
      expect(controller.repeatOne.value, isTrue);

      // …and the next natural end replays the row we skipped to.
      controller.notifyYoutubeItemEnded(itemId: 2);
      await _settle();
      expect(controller.currentIndex.value, 1);
    });
  });
}
