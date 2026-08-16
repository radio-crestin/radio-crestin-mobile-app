import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_reconciler.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/playlist_item.dart';

/// Tests for "next at the end of a playlist continues with the next STATION".
///
/// The rule only applies to an explicit user press (transport button, lock
/// screen, steering wheel): on the LAST playable item, "next" leaves the
/// playlist station and plays the next station in the frozen order — whatever
/// kind it is. "Previous" on the FIRST item mirrors it. Everything else is
/// unchanged: inside the list a press moves one row, single-item repeat wins
/// over the hand-over, and auto-advance at the natural end of an item still
/// loops around the playlist.
///
/// The decision itself is pure ([PlaylistNavigator.shouldLeaveStation]) so the
/// interesting cases need no player at all; the controller tests then pin the
/// wiring to [AppAudioHandler.skipToNextStation] / `skipToPreviousStation`.

PlaylistItem _item(int id, PlaylistItemType type) => PlaylistItem(
      id: id,
      order: id,
      type: type,
      url: 'https://cdn/$id',
      title: 'Item $id',
    );

PlaylistItem _audio(int id) => _item(id, PlaylistItemType.audio);
PlaylistItem _yt(int id) => _item(id, PlaylistItemType.youtube);

/// A stand-in for the real handler: only the members the skip path touches.
class _FakeAudioHandler extends Fake implements AppAudioHandler {
  /// Item indexes handed to the handler, in order — i.e. what actually played.
  final List<int> playedIndexes = [];

  /// Station-level hand-overs, in order ('next' / 'previous').
  final List<String> stationSkips = [];

  /// Ordered trace of the teardown calls the controller makes on the handler,
  /// used to pin that the YouTube iframe is paused BEFORE it is unmounted.
  final List<String> teardown = [];

  bool carConnected = false;

  @override
  void resetVideoFallback() {}

  @override
  bool get isVideoModeActive => false;

  @override
  bool get isForeground => true;

  @override
  bool get isCarConnected => carConnected;

  @override
  bool get isCasting => false;

  @override
  Future<void> skipToNextStation() async => stationSkips.add('next');

  @override
  Future<void> skipToPreviousStation() async => stationSkips.add('previous');

  @override
  void updatePlaylistMediaItem(
    PlaylistItem item, {
    required int index,
    required int count,
  }) =>
      playedIndexes.add(index);

  @override
  Future<void> stopPlaylistPlayback() async => teardown.add('stopPlayback');

  @override
  Future<void> pauseFromUser() async => teardown.add('pauseFromUser');

  @override
  void exitPlaylistMode() {}

  @override
  void enterPlaylistMode() {}

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

/// Lets the fire-and-forget `playItemAt` triggered by a skip run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('PlaylistNavigator.shouldLeaveStation', () {
    final items = [_audio(1), _audio(2), _audio(3)];

    bool leave(int fromIndex,
            {int direction = 1,
            bool repeatOne = false,
            bool skipYoutube = false,
            List<PlaylistItem>? list}) =>
        PlaylistNavigator.shouldLeaveStation(
          items: list ?? items,
          fromIndex: fromIndex,
          skipYoutube: skipYoutube,
          repeatOne: repeatOne,
          direction: direction,
        );

    test('next on the LAST item leaves for the next station', () {
      expect(leave(2), isTrue);
    });

    test('next anywhere else stays inside the playlist', () {
      expect(leave(0), isFalse);
      expect(leave(1), isFalse);
    });

    test('previous on the FIRST item leaves for the previous station', () {
      expect(leave(0, direction: -1), isTrue);
    });

    test('previous anywhere else stays inside the playlist', () {
      expect(leave(1, direction: -1), isFalse);
      expect(leave(2, direction: -1), isFalse);
    });

    test('repeat armed always wins — no station hand-over', () {
      expect(leave(2, repeatOne: true), isFalse);
      expect(leave(0, direction: -1, repeatOne: true), isFalse);
    });

    test('a single-item playlist hands over in both directions', () {
      final one = [_audio(1)];
      expect(leave(0, list: one), isTrue);
      expect(leave(0, direction: -1, list: one), isTrue);
    });

    test('trailing unplayable items still count as the end (car: youtube)', () {
      // In a car session youtube rows can't play, so the last AUDIO row is the
      // real last item — pressing next there must hand over, not stall.
      final mixed = [_audio(1), _audio(2), _yt(3)];
      expect(leave(1, skipYoutube: true, list: mixed), isTrue);
      expect(leave(1, skipYoutube: false, list: mixed), isFalse);
    });

    test('an empty list or an unpositioned playlist never hands over', () {
      expect(leave(0, list: const []), isFalse);
      expect(leave(-1), isFalse);
    });
  });

  group('PlaylistController user skip at the playlist edge', () {
    late _FakeAudioHandler handler;
    late PlaylistController controller;

    /// Seeds a three-row audio playlist positioned on [index].
    void seed(int index, {List<PlaylistItem>? list}) {
      final items = list ?? [_audio(1), _audio(2), _audio(3)];
      controller.items.add(items);
      controller.currentIndex.add(index);
      controller.currentItem.add(items[index]);
    }

    setUp(() async {
      handler = _FakeAudioHandler();
      await GetIt.instance.reset();
      GetIt.instance.registerSingleton<AppAudioHandler>(handler);
      controller = PlaylistController(
        videoService: VideoPlaybackService(),
        syncService: PlaylistSyncService(),
      );
    });

    tearDown(() async {
      controller.dispose();
      await GetIt.instance.reset();
    });

    test('next on the last item advances to the next STATION', () async {
      // Arrange.
      seed(2);

      // Act.
      await controller.skipToNext();
      await _settle();

      // Assert: the station list took over; no item wrapped to the top.
      expect(handler.stationSkips, ['next']);
      expect(handler.playedIndexes, isEmpty);
      expect(controller.currentIndex.value, 2);
    });

    test('next inside the list still advances one item', () async {
      // Arrange.
      seed(1);

      // Act.
      await controller.skipToNext();
      await _settle();

      // Assert.
      expect(handler.stationSkips, isEmpty);
      expect(handler.playedIndexes, [2]);
      expect(controller.currentIndex.value, 2);
    });

    test('previous on the first item advances to the previous STATION',
        () async {
      // Arrange.
      seed(0);

      // Act.
      await controller.skipToPrevious();
      await _settle();

      // Assert.
      expect(handler.stationSkips, ['previous']);
      expect(handler.playedIndexes, isEmpty);
    });

    test('previous inside the list still goes back one item', () async {
      // Arrange.
      seed(2);

      // Act.
      await controller.skipToPrevious();
      await _settle();

      // Assert.
      expect(handler.stationSkips, isEmpty);
      expect(handler.playedIndexes, [1]);
    });

    test('repeat armed keeps next on the last item inside the playlist',
        () async {
      // Arrange: repeat semantics win over the station hand-over.
      seed(2);
      controller.repeatOne.add(true);

      // Act.
      await controller.skipToNext();
      await _settle();

      // Assert: the old looping behavior (wrap to the top row).
      expect(handler.stationSkips, isEmpty);
      expect(handler.playedIndexes, [0]);
      expect(controller.currentIndex.value, 0);
    });

    test('leaving a YouTube item pauses the iframe BEFORE unmounting it',
        () async {
      // Arrange: a YouTube item is the active one (a UI-owned webview).
      seed(0, list: [_yt(1), _yt(2)]);
      final shouldPlay = <bool>[];
      controller.youtubeShouldPlay.stream.listen(shouldPlay.add);
      final requests = <int?>[];
      controller.youtubeRequest.stream.listen((i) => requests.add(i?.id));

      // Act: the station advance tears the playlist down.
      await controller.stop();

      // Assert: the pause command reaches the iframe first, and the widget is
      // only dropped afterwards. A webview destroyed mid-playback makes iOS
      // deliver a stray remote-command pause onto the NEXT station's stream —
      // the "Postul următor doesn't start playing" bug.
      expect(shouldPlay.last, isFalse);
      expect(requests.last, isNull);
      expect(controller.currentItem.value, isNull);
    });

    test('a UI pause routes through pauseFromUser (never the guarded pause)',
        () async {
      seed(0);

      await controller.pause();

      expect(handler.teardown, ['pauseFromUser']);
    });

    test('auto-advance at the natural end of the last item still loops',
        () async {
      // Arrange: only an explicit press hands over — an item that simply
      // finishes keeps the playlist playing (unchanged behavior).
      seed(2, list: [_yt(1), _yt(2), _yt(3)]);

      // Act.
      controller.notifyYoutubeItemEnded(itemId: 3);
      await _settle();

      // Assert.
      expect(handler.stationSkips, isEmpty);
      expect(controller.currentIndex.value, 0);
    });
  });
}
