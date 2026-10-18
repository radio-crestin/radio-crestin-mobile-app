import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fakes the just_audio plugin at its method and event channels, so a real
/// `AudioPlayer` (and the `AppAudioHandler` around it) can load, play,
/// pause and stop in a unit test. Also silences the PostHog channel the
/// handler's analytics call into.
///
/// Every load succeeds and reports `ready` at once, unless its URL contains
/// one of [failingUrlParts]. Like the native players, nothing here flips
/// `playing` on a reload while playing: just_audio tracks `playing` itself.
/// A `play` call answers at once, unless [holdPlayUntilStopped] is on.
class FakeJustAudioChannels {
  static const _mainChannel = MethodChannel('com.ryanheise.just_audio.methods');
  static const _posthogChannel = MethodChannel('posthog_flutter');

  /// Window length a live HLS load reports as its duration.
  static const liveWindow = Duration(minutes: 10);

  /// Every URL loaded, in order.
  final List<String> loads = [];

  /// Every seek target, in order (null: seek to the item's start).
  final List<Duration?> seeks = [];

  /// A load whose URL contains one of these fails, with [failureCode].
  final Set<String> failingUrlParts = {};

  /// The error code of a failing load: an HTTP status like the default
  /// 404, or e.g. `0`, how ExoPlayer reports a network failure.
  String failureCode = '404';

  /// How long each load takes before it succeeds or fails.
  Duration loadDelay = Duration.zero;

  /// When set, each load also waits for this to complete before it
  /// succeeds or fails, so a test holds a load in flight for exactly as
  /// long as it needs, however slowly the test runs.
  Completer<void>? loadGate;

  /// Every URL whose load ended (succeeded or failed), in order.
  final List<String> finishedLoads = [];

  /// Whether a `play` call answers only once its player pauses or is
  /// disposed (and at once if it already plays), as the native plugins
  /// do: `AudioPlayer.play()` then completes only when playback stops.
  /// Off by default, since the handler's play() returns the main player's
  /// play() and the tests await it.
  bool holdPlayUntilStopped = false;

  /// Whether a `play` call on a ready player answers with buffering, as
  /// AVPlayer does while it waits for data; [emitProcessingState] then
  /// says it plays. Off by default: ready players play at once.
  bool waitsAfterPlay = false;

  /// Whether live loads follow AVPlayer's geometry: the reported duration
  /// (its seekable range) ends [avPlayerHoldBack] before the end of
  /// [liveWindow], a start variant (`index-2m.m3u8`, `index-5m.m3u8`)
  /// loads where its `#EXT-X-START` puts it (2 or 5 minutes before the
  /// end), `index.m3u8` at the live point (the end of the seekable range),
  /// and a seek moves the reported position. Off by default: the duration
  /// is [liveWindow] and every report is at position 0.
  bool avPlayerLiveGeometry = false;

  /// How far AVPlayer's seekable range ends before the playlist: three
  /// target durations.
  static const avPlayerHoldBack = Duration(seconds: 18);

  /// The buffered position every native player reports: where what the
  /// player loaded ends.
  Duration bufferedPosition = Duration.zero;

  /// Whether a native player plays: told to play, and not paused or
  /// disposed since. just_audio's stop() disposes the native player.
  bool get isAnyPlayerPlaying => _players.values.any((p) => p._playing);

  /// The id of every native player created, in order: just_audio creates
  /// one per activation, as for the first load after a stop().
  final List<String> createdPlayers = [];

  /// The id of every native player disposed, in order: just_audio's
  /// stop() disposes its native player.
  final List<String> disposedPlayers = [];

  /// How many times a native player was told to pause.
  int pauses = 0;

  final Map<String, _FakeNativePlayer> _players = {};

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(_mainChannel, _onMainCall);
    _messenger.setMockMethodCallHandler(_posthogChannel, (_) async => null);
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(_mainChannel, null);
    _messenger.setMockMethodCallHandler(_posthogChannel, null);
    for (final player in _players.values) {
      player.unregister(_messenger);
    }
    _players.clear();
  }

  /// Emits a SHOUTcast `StreamTitle` on every native player.
  void emitIcyTitle(String title) {
    for (final player in _players.values) {
      player.emit(icyTitle: title);
    }
  }

  /// Reports [position] buffered on every native player, as a player that
  /// loaded more media does.
  void emitBufferedPosition(Duration position) {
    bufferedPosition = position;
    for (final player in _players.values) {
      player.emit();
    }
  }

  /// Puts every native player in the `ProcessingStateMessage` [state]
  /// (0 idle, 1 loading, 2 buffering, 3 ready, 4 completed), as a stream
  /// whose buffer ran dry (buffering) or that died (idle) reports it.
  void emitProcessingState(int state) {
    for (final player in _players.values) {
      player
        .._state = state
        ..emit();
    }
  }

  Future<Object?> _onMainCall(MethodCall call) async {
    switch (call.method) {
      case 'init':
        final id = (call.arguments as Map)['id'] as String;
        createdPlayers.add(id);
        _players[id] = _FakeNativePlayer(id, this)..register(_messenger);
        return null;
      case 'disposePlayer':
        final id = (call.arguments as Map)['id'] as String;
        disposedPlayers.add(id);
        // Like the native dispose, this answers a pending play call.
        _players.remove(id)?.unregister(_messenger);
        return <String, Object?>{};
      default:
        return <String, Object?>{};
    }
  }
}

/// One native player instance (just_audio creates a new one per activation).
class _FakeNativePlayer {
  _FakeNativePlayer(this.id, this.owner);

  final String id;
  final FakeJustAudioChannels owner;
  MockStreamHandlerEventSink? _events;
  int _state = 0; // ProcessingStateMessage.idle
  Duration? _duration;
  Duration _position = Duration.zero;
  String? _icyTitle;
  bool _playing = false;
  // The held answer to a play call (see holdPlayUntilStopped).
  Completer<Object?>? _playResult;

  MethodChannel get _methods =>
      MethodChannel('com.ryanheise.just_audio.methods.$id');
  EventChannel get _eventChannel =>
      EventChannel('com.ryanheise.just_audio.events.$id');
  EventChannel get _dataChannel =>
      EventChannel('com.ryanheise.just_audio.data.$id');

  void register(TestDefaultBinaryMessenger messenger) {
    messenger.setMockMethodCallHandler(_methods, _onCall);
    messenger.setMockStreamHandler(
      _eventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => _events = events,
        onCancel: (_) => _events = null,
      ),
    );
    messenger.setMockStreamHandler(
        _dataChannel, MockStreamHandler.inline(onListen: (_, __) {}));
  }

  void unregister(TestDefaultBinaryMessenger messenger) {
    _stopPlaying();
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockStreamHandler(_eventChannel, null);
    messenger.setMockStreamHandler(_dataChannel, null);
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'load':
        final request = call.arguments as Map;
        final gate = owner.loadGate;
        if (owner.loadDelay > Duration.zero || gate != null) {
          owner.loads.add(_firstUri(request['audioSource']) ?? '');
          await Future<void>.delayed(owner.loadDelay);
          await gate?.future;
          return _load(request, counted: true);
        }
        return _load(request);
      case 'seek':
        final micros = (call.arguments as Map)['position'] as int?;
        owner.seeks.add(micros == null ? null : Duration(microseconds: micros));
        if (owner.avPlayerLiveGeometry) {
          _position = Duration(microseconds: micros ?? 0);
        }
        emit();
        return <String, Object?>{};
      case 'play':
        final hold = owner.holdPlayUntilStopped && !_playing;
        if (owner.waitsAfterPlay && !_playing && _state == 3) _state = 2;
        _playing = true;
        emit();
        if (!hold) return <String, Object?>{};
        _answerPlay();
        return (_playResult = Completer<Object?>()).future;
      case 'pause':
        owner.pauses++;
        _stopPlaying();
        emit();
        return <String, Object?>{};
      default:
        return <String, Object?>{};
    }
  }

  void _stopPlaying() {
    _playing = false;
    _answerPlay();
  }

  void _answerPlay() {
    _playResult?.complete(<String, Object?>{});
    _playResult = null;
  }

  Map<String, Object?> _load(Map request, {bool counted = false}) {
    final url = _firstUri(request['audioSource']) ?? '';
    if (!counted) owner.loads.add(url);
    owner.finishedLoads.add(url);
    if (owner.failingUrlParts.any(url.contains)) {
      throw PlatformException(
          code: owner.failureCode, message: 'Failed to load: $url');
    }
    _duration = url.contains('.m3u8') ? _liveDuration() : null;
    _position = _startPosition(url);
    _state = 3; // ProcessingStateMessage.ready
    emit();
    return {'duration': _duration?.inMicroseconds ?? -1};
  }

  Duration _liveDuration() {
    const window = FakeJustAudioChannels.liveWindow;
    return owner.avPlayerLiveGeometry
        ? window - FakeJustAudioChannels.avPlayerHoldBack
        : window;
  }

  Duration _startPosition(String url) {
    if (!owner.avPlayerLiveGeometry || !url.contains('.m3u8')) {
      return Duration.zero;
    }
    const window = FakeJustAudioChannels.liveWindow;
    if (url.contains('/index-2m.m3u8')) {
      return window - const Duration(minutes: 2);
    }
    if (url.contains('/index-5m.m3u8')) {
      return window - const Duration(minutes: 5);
    }
    // index.m3u8: its #EXT-X-START (-18 s) is the end of the seekable range.
    return _liveDuration();
  }

  /// Sends the current playback event, optionally with an ICY title.
  void emit({String? icyTitle}) {
    if (icyTitle != null) _icyTitle = icyTitle;
    final title = _icyTitle;
    _events?.success(<String, Object?>{
      'processingState': _state,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
      'updatePosition': _position.inMicroseconds,
      'bufferedPosition': owner.bufferedPosition.inMicroseconds,
      'duration': _duration?.inMicroseconds ?? -1,
      'icyMetadata': title == null
          ? null
          : {
              'info': {'title': title, 'url': null},
              'headers': null,
            },
      'currentIndex': 0,
    });
  }

  static String? _firstUri(Object? source) {
    if (source is! Map) return null;
    final uri = source['uri'];
    if (uri is String) return uri;
    final children = source['children'];
    if (children is List) {
      for (final child in children) {
        final found = _firstUri(child);
        if (found != null) return found;
      }
    }
    return null;
  }
}
