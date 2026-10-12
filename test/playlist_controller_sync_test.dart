import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/types/playlist_item.dart';

import 'helpers/station_factory.dart';

/// Controller-level tests for the live playlist sync, the session-scoped
/// position sampler and the background-start poll suspension.
///
/// The handler, its just_audio player and the sync service are fakes: no real
/// player, network or platform channel is involved.

/// Fake just_audio player. Only [position] and [durationStream] may be used;
/// any other access (e.g. `positionStream`, whose internal timer can't be
/// cancelled) throws and fails the test.
class _FakePlayer implements AudioPlayer {
  @override
  Duration position = Duration.zero;

  final StreamController<Duration?> _durations =
      StreamController<Duration?>.broadcast();

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHandler extends BaseAudioHandler implements AppAudioHandler {
  @override
  final _FakePlayer player = _FakePlayer();

  @override
  bool isForeground = true;

  @override
  bool isCarConnected = false;

  @override
  bool get isCasting => false;

  @override
  bool get isVideoModeActive => false;

  @override
  VoidCallback? onPlaylistItemCompleted;

  @override
  void Function(Object error)? onPlaylistItemError;

  final List<String> playedUrls = [];
  int stopPlaybackCalls = 0;

  @override
  Future<void> playPlaylistAudioItem(String url,
      {Duration? startPosition}) async {
    playedUrls.add(url);
  }

  @override
  Future<void> stopPlaylistPlayback() async => stopPlaybackCalls++;

  // Remaining members used by the controller return void.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSync implements PlaylistSyncService {
  final StreamController<List<PlaylistItem>> _updates =
      StreamController<List<PlaylistItem>>.broadcast();
  final List<String> calls = [];

  @override
  Stream<List<PlaylistItem>> get updates => _updates.stream;

  @override
  void startSync(String stationSlug) => calls.add('start:$stationSlug');

  @override
  void stopSync() => calls.add('stop');

  @override
  void pause() => calls.add('pause');

  @override
  void resume() => calls.add('resume');

  /// Delivers a poll result and lets the broadcast listener run.
  Future<void> emit(List<PlaylistItem> items) async {
    _updates.add(items);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A REST-shaped item, as a fresh instance per call (like a new poll parse).
PlaylistItem _rest(int id, {String type = 'audio', String? title}) =>
    PlaylistItem.fromJson({
      'id': id,
      'order': id,
      'type': type,
      'url': 'https://cdn/$id',
      'title': title ?? 'Item $id',
    });

Station _station(List<PlaylistItem> items) => StationFactory.createStation(
      id: 1,
      slug: 'pl',
      title: 'Playlist',
      stationType: 'playlist',
      playlistItems: [
        for (final i in items)
          StationFactory.createPlaylistItem(
            id: i.id,
            order: i.order,
            type: switch (i.type) {
              PlaylistItemType.youtube => 'youtube',
              _ => 'audio',
            },
            url: i.url,
            title: i.title,
          ),
      ],
    );

void main() {
  late _FakeHandler handler;
  late _FakeSync sync;
  late PlaylistController controller;

  setUp(() {
    handler = _FakeHandler();
    sync = _FakeSync();
    if (GetIt.I.isRegistered<AppAudioHandler>()) {
      GetIt.I.unregister<AppAudioHandler>();
    }
    GetIt.I.registerSingleton<AppAudioHandler>(handler);
    controller = PlaylistController(
      videoService: VideoPlaybackService(),
      syncService: sync,
    );
  });

  tearDown(() async {
    controller.dispose();
    await GetIt.I.reset();
  });

  group('PlaylistItem value equality', () {
    test('two parses of the same entry are equal with equal hashCodes', () {
      expect(_rest(1), _rest(1));
      expect(_rest(1).hashCode, _rest(1).hashCode);
    });

    test('any field change makes items unequal', () {
      expect(_rest(1), isNot(_rest(1, title: 'Renamed')));
      expect(_rest(1), isNot(_rest(1, type: 'youtube')));
      expect(_rest(1), isNot(_rest(2)));
    });
  });

  group('live sync emits only real changes', () {
    setUp(() async {
      await controller.startPlaylist(_station([_rest(1), _rest(2)]));
    });

    test('an unchanged poll re-emits nothing (no rebuild / re-scroll)',
        () async {
      final emitted = <String>[];
      final subs = [
        controller.items.skip(1).listen((_) => emitted.add('items')),
        controller.currentIndex.skip(1).listen((_) => emitted.add('index')),
        controller.currentItem.skip(1).listen((_) => emitted.add('item')),
      ];

      await sync.emit([_rest(1), _rest(2)]);
      await sync.emit([_rest(1), _rest(2)]);

      expect(emitted, isEmpty);
      for (final s in subs) {
        await s.cancel();
      }
    });

    test('a new item on top moves the index but keeps the current item',
        () async {
      final emitted = <String>[];
      final subs = [
        controller.items.skip(1).listen((_) => emitted.add('items')),
        controller.currentIndex.skip(1).listen((_) => emitted.add('index')),
        controller.currentItem.skip(1).listen((_) => emitted.add('item')),
      ];

      await sync.emit([_rest(9), _rest(1), _rest(2)]);

      expect(emitted, ['items', 'index']);
      expect(controller.currentIndex.value, 1);
      expect(controller.currentItem.value?.id, 1);
      expect(handler.playedUrls, ['https://cdn/1'], reason: 'no restart');
      for (final s in subs) {
        await s.cancel();
      }
    });

    test('a retitled current item updates currentItem only', () async {
      await sync.emit([_rest(1, title: 'New title'), _rest(2)]);
      expect(controller.currentItem.value?.title, 'New title');
      expect(handler.playedUrls, ['https://cdn/1'], reason: 'no restart');
    });
  });

  group('current item removed by the curator', () {
    test('skips a youtube survivor in car and plays the next audio item',
        () async {
      handler.isCarConnected = true;
      await controller.startPlaylist(
          _station([_rest(1), _rest(2, type: 'youtube'), _rest(3)]));

      await sync.emit([_rest(2, type: 'youtube'), _rest(3)]);

      expect(controller.currentIndex.value, 1);
      expect(controller.currentItem.value?.id, 3);
      expect(handler.playedUrls.last, 'https://cdn/3');
    });

    test('plays the youtube survivor itself on the phone (no car/cast)',
        () async {
      await controller.startPlaylist(
          _station([_rest(1), _rest(2, type: 'youtube'), _rest(3)]));

      await sync.emit([_rest(2, type: 'youtube'), _rest(3)]);

      expect(controller.currentIndex.value, 0);
      expect(controller.youtubeRequest.value?.id, 2);
    });

    test('nothing playable left: clears the index and stays active',
        () async {
      handler.isCarConnected = true;
      await controller.startPlaylist(
          _station([_rest(1), _rest(2, type: 'youtube')]));
      final stopsBefore = handler.stopPlaybackCalls;

      await sync.emit([_rest(2, type: 'youtube')]);

      expect(controller.currentIndex.value, -1);
      expect(controller.currentItem.value, isNull);
      expect(handler.stopPlaybackCalls, stopsBefore + 1);
      expect(controller.isActive, isTrue);
    });
  });

  group('live sync lifecycle', () {
    test('a playlist started in the foreground keeps polling', () async {
      await controller.startPlaylist(_station([_rest(1)]));
      expect(sync.calls, ['start:pl']);
    });

    test('a playlist started while backgrounded suspends the poll', () async {
      handler.isForeground = false;
      await controller.startPlaylist(_station([_rest(1)]));
      expect(sync.calls, ['start:pl', 'pause']);
    });
  });

  group('position sampling is scoped to the playlist session', () {
    test('samples just_audio position, including a seek while paused',
        () async {
      await controller.startPlaylist(_station([_rest(1)]));
      handler.player.position = const Duration(seconds: 7);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(controller.position.value, const Duration(seconds: 7));
    });

    test('stops sampling once the playlist stops', () async {
      await controller.startPlaylist(_station([_rest(1)]));
      await controller.stop();
      handler.player.position = const Duration(seconds: 42);

      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(controller.position.value, Duration.zero);
    });
  });
}
