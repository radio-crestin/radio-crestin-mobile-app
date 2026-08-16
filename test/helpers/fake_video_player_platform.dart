// video_player_platform_interface ships as a transitive dependency of
// video_player; this test double needs it directly to install a fake platform.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

// Re-exported so test files can install/drive the fake without importing the
// transitive package themselves.
export 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show VideoEvent, VideoEventType, VideoPlayerPlatform;

/// How a fake player behaves once `initialize()` subscribes to its event
/// stream.
enum FakeInitBehavior {
  /// Emits `initialized` immediately — `initialize()` resolves.
  succeed,

  /// Emits a [PlatformException] on the event stream — `initialize()` throws.
  fail,

  /// Emits nothing; the test drives the outcome by hand with
  /// [FakeVideoPlayerPlatform.completeInit] or
  /// [FakeVideoPlayerPlatform.failInit].
  manual,
}

/// The scripted behavior of one media URL.
class FakeMediaScript {
  const FakeMediaScript({
    this.behavior = FakeInitBehavior.succeed,
    this.size = const Size(1280, 720),
    this.duration = const Duration(minutes: 2),
    this.errorMessage = 'fake player error',
  });

  final FakeInitBehavior behavior;
  final Size size;
  final Duration duration;
  final String errorMessage;
}

/// A controllable in-memory [VideoPlayerPlatform] for unit/widget tests.
///
/// Each `VideoPlayerController.networkUrl(...)` becomes a fake "player" with an
/// incrementing id. Behavior is scripted per URL ([script]) so a test can make
/// one media initialize instantly, another fail, and a third hang until the
/// test decides — which is what the supersession / preload-then-swap paths in
/// `VideoPlaybackService` need.
///
/// Every platform call is recorded so tests can assert on ordering (e.g. that a
/// quality preload was muted before it was swapped in).
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<String, FakeMediaScript> scripts = {};

  /// Player ids in creation order.
  final List<int> created = [];

  /// Player ids passed to `dispose`, in order.
  final List<int> disposed = [];

  /// Player ids passed to `play` / `pause`, in order.
  final List<int> played = [];
  final List<int> paused = [];

  /// `(playerId, volume)` in call order.
  final List<MapEntry<int, double>> volumes = [];

  /// `(playerId, position)` in call order.
  final List<MapEntry<int, Duration>> seeks = [];

  /// playerId → the URL it was created for.
  final Map<int, String> uriOf = {};

  /// URL → the ids created for it, in order.
  final Map<String, List<int>> idsOf = {};

  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, Duration> _positions = {};

  int _nextId = 1;

  /// Registers [script] for [url].
  void script(String url, FakeMediaScript script) => scripts[url] = script;

  /// The single id created for [url] (fails when there is not exactly one).
  int idFor(String url) {
    final ids = idsOf[url];
    if (ids == null || ids.length != 1) {
      throw StateError('expected exactly one player for $url, got $ids');
    }
    return ids.single;
  }

  /// The most recent id created for [url].
  int lastIdFor(String url) => idsOf[url]!.last;

  List<double> volumesFor(int playerId) => volumes
      .where((e) => e.key == playerId)
      .map((e) => e.value)
      .toList(growable: false);

  bool isDisposed(int playerId) => disposed.contains(playerId);

  /// Emits an `initialized` event for a [FakeInitBehavior.manual] player.
  void completeInit(
    int playerId, {
    Size size = const Size(1280, 720),
    Duration duration = const Duration(minutes: 2),
  }) {
    _events[playerId]?.add(VideoEvent(
      eventType: VideoEventType.initialized,
      duration: duration,
      size: size,
    ));
  }

  /// Fails a pending (or already initialized) player with [message].
  void failInit(int playerId, {String message = 'fake player error'}) {
    _events[playerId]?.addError(
      PlatformException(code: 'VideoError', message: message),
    );
  }

  /// Emits an arbitrary event on [playerId]'s stream (buffering, completion…).
  void emit(int playerId, VideoEvent event) => _events[playerId]?.add(event);

  /// Sets the position `getPosition` reports for [playerId].
  void setPosition(int playerId, Duration position) =>
      _positions[playerId] = position;

  /// Closes every open event stream (call from `tearDown`).
  Future<void> shutdown() async {
    for (final controller in _events.values) {
      await controller.close();
    }
    _events.clear();
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final url = options.dataSource.uri ?? options.dataSource.asset ?? '';
    created.add(id);
    uriOf[id] = url;
    (idsOf[url] ??= []).add(id);
    _positions[id] = Duration.zero;
    _events[id] = StreamController<VideoEvent>.broadcast(
      onListen: () => _runScript(id, url),
    );
    return id;
  }

  void _runScript(int id, String url) {
    final script = scripts[url] ?? const FakeMediaScript();
    switch (script.behavior) {
      case FakeInitBehavior.succeed:
        scheduleMicrotask(() => completeInit(
              id,
              size: script.size,
              duration: script.duration,
            ));
      case FakeInitBehavior.fail:
        scheduleMicrotask(() => failInit(id, message: script.errorMessage));
      case FakeInitBehavior.manual:
        break;
    }
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _events[playerId]?.stream ?? const Stream<VideoEvent>.empty();

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async => played.add(playerId);

  @override
  Future<void> pause(int playerId) async => paused.add(playerId);

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      volumes.add(MapEntry(playerId, volume));

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add(MapEntry(playerId, position));
    _positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      _positions[playerId] ?? Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allow) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand(key: ValueKey('fake-video-view'));
}
