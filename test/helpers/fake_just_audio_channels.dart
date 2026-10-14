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

  /// Every URL whose load ended (succeeded or failed), in order.
  final List<String> finishedLoads = [];

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
        _players[id] = _FakeNativePlayer(id, this)..register(_messenger);
        return null;
      case 'disposePlayer':
        final id = (call.arguments as Map)['id'] as String;
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
  String? _icyTitle;

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
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockStreamHandler(_eventChannel, null);
    messenger.setMockStreamHandler(_dataChannel, null);
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'load':
        final request = call.arguments as Map;
        if (owner.loadDelay > Duration.zero) {
          owner.loads.add(_firstUri(request['audioSource']) ?? '');
          await Future<void>.delayed(owner.loadDelay);
          return _load(request, counted: true);
        }
        return _load(request);
      case 'seek':
        final micros = (call.arguments as Map)['position'] as int?;
        owner.seeks.add(micros == null ? null : Duration(microseconds: micros));
        emit();
        return <String, Object?>{};
      case 'play':
      case 'pause':
        emit();
        return <String, Object?>{};
      default:
        return <String, Object?>{};
    }
  }

  Map<String, Object?> _load(Map request, {bool counted = false}) {
    final url = _firstUri(request['audioSource']) ?? '';
    if (!counted) owner.loads.add(url);
    owner.finishedLoads.add(url);
    if (owner.failingUrlParts.any(url.contains)) {
      throw PlatformException(
          code: owner.failureCode, message: 'Failed to load: $url');
    }
    _duration = url.contains('.m3u8') ? FakeJustAudioChannels.liveWindow : null;
    _state = 3; // ProcessingStateMessage.ready
    emit();
    return {'duration': _duration?.inMicroseconds ?? -1};
  }

  /// Sends the current playback event, optionally with an ICY title.
  void emit({String? icyTitle}) {
    if (icyTitle != null) _icyTitle = icyTitle;
    final title = _icyTitle;
    _events?.success(<String, Object?>{
      'processingState': _state,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
      'updatePosition': 0,
      'bufferedPosition': 0,
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
