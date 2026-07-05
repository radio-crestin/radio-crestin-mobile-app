import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:rxdart/rxdart.dart';

/// Wraps a single media_kit ([Player] + [VideoController]) for the app's
/// "video mode": TV channels and video playlist items played with perfect
/// audio+video sync via libmpv.
///
/// Created lazily (the first [ensureInitialized]/[open]) and kept alive for
/// reuse; [stop] halts playback without tearing down the texture so switching
/// items is fast, while [dispose] fully releases native resources.
///
/// The buffering is tuned to mirror the just_audio path's philosophy (generous
/// forward + back cache) so a network blip during video playback doesn't stall
/// the picture — see [_configureBuffering].
///
/// This service is deliberately unaware of `MediaItem`/`playbackState`: it only
/// plays pixels and audio and exposes playback streams. [AppAudioHandler] is
/// responsible for mapping these events onto the notification/lock-screen.
class VideoPlaybackService {
  VideoPlaybackService();

  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _live = false;
  bool _muted = false;
  double _volume = 1.0;

  // Seeded so the UI/handler can subscribe before the first [open].
  final BehaviorSubject<Duration> _position =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _duration =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<bool> _buffering = BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<bool> _playing = BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<bool> _completed = BehaviorSubject<bool>.seeded(false);
  final PublishSubject<String> _error = PublishSubject<String>();

  /// True once the decoder has produced a first video frame for the CURRENT
  /// media (reset on every [open]). Drives the video→audio fallback watchdog:
  /// on a platform that can't decode the codec (e.g. libmpv on the iOS
  /// simulator) this stays false while the picture buffers forever, so the
  /// handler can hand off to audio-only. Derived from the player's width/height
  /// streams — non-null positive dimensions mean a frame was decoded.
  final BehaviorSubject<bool> _hasFrame = BehaviorSubject<bool>.seeded(false);
  int? _lastWidth;
  int? _lastHeight;

  /// Demuxer cache size (bytes). 64 MB — double media_kit's 32 MB default so a
  /// live TV stream keeps several seconds of video buffered against jitter.
  static const int _bufferSizeBytes = 64 * 1024 * 1024;

  // ── Public state ──────────────────────────────────────────────────────────

  /// Whether the underlying player has been created.
  bool get isInitialized => _player != null;

  /// The video output controller for the UI's `Video(controller: ...)` widget.
  /// Null until [ensureInitialized]/[open] has run.
  VideoController? get controller => _controller;

  /// The underlying media_kit player. Prefer the wrapper methods; exposed for
  /// advanced UI needs (e.g. track selection).
  Player? get player => _player;

  /// True when the current media was opened as a live stream (no seekable VOD
  /// timeline). Drives `isLive` on the lock-screen media item.
  bool get isLive => _live;

  Duration get position => _player?.state.position ?? Duration.zero;
  Duration get duration => _player?.state.duration ?? Duration.zero;
  bool get isPlaying => _player?.state.playing ?? false;
  bool get isBuffering => _player?.state.buffering ?? false;

  /// Current playback position (VOD). Fires continuously while playing.
  Stream<Duration> get positionStream => _position.stream;

  /// Total media duration; `Duration.zero` for live streams.
  Stream<Duration> get durationStream => _duration.stream;

  /// True while the decoder is waiting on data.
  Stream<bool> get bufferingStream => _buffering.stream;

  /// True while actively playing, false when paused.
  Stream<bool> get playingStream => _playing.stream;

  /// Emits `true` once when the media reaches its end (VOD auto-advance).
  Stream<bool> get completedStream => _completed.stream;

  /// Emits a libmpv error string when playback fails.
  Stream<String> get errorStream => _error.stream;

  /// Emits `true` once the CURRENT media renders a first video frame (reset to
  /// `false` on every [open]). See [_hasFrame].
  Stream<bool> get hasFrameStream => _hasFrame.stream;

  /// Whether the current media has rendered a first video frame yet.
  bool get hasRenderedFrame => _hasFrame.value;

  // ── Lifecycle ───────────────────────────────────────────────────────────

  /// Lazily creates the [Player] + [VideoController] and wires its streams.
  /// Idempotent — safe to call before every [open].
  Future<VideoController> ensureInitialized() async {
    final existing = _controller;
    if (existing != null) return existing;

    // media_kit must be initialized once before any Player is constructed.
    // This is the single init point (main.dart defers to here), so it runs on
    // first video use rather than at startup. Timed so the deferred cost is
    // visible in logs.
    final initSw = Stopwatch()..start();
    MediaKit.ensureInitialized();
    initSw.stop();
    debugPrint('VideoPlaybackService: MediaKit.ensureInitialized() took '
        '${initSw.elapsedMilliseconds}ms (deferred to first video)');

    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: _bufferSizeBytes,
        // 'video' matches the app's use — libmpv keeps video decoding warm.
        title: 'Radio Crestin',
      ),
    );
    _player = player;
    await _configureBuffering(player);

    final controller = VideoController(player);
    _controller = controller;

    _subs.add(player.stream.position.listen(_position.add));
    _subs.add(player.stream.duration.listen(_duration.add));
    _subs.add(player.stream.buffering.listen(_buffering.add));
    _subs.add(player.stream.playing.listen(_playing.add));
    _subs.add(player.stream.completed.listen(_completed.add));
    _subs.add(player.stream.error.listen((e) {
      debugPrint('VideoPlaybackService: player error: $e');
      _error.add(e);
    }));
    // First-frame detection: the decoder reports the video's pixel dimensions
    // only once it has actually decoded a frame. Track both and flip [_hasFrame]
    // when they are known & positive. On the iOS simulator libmpv never decodes
    // the frame, so these never arrive and the fallback watchdog fires.
    _subs.add(player.stream.width.listen((w) {
      _lastWidth = w;
      _recomputeHasFrame();
    }));
    _subs.add(player.stream.height.listen((h) {
      _lastHeight = h;
      _recomputeHasFrame();
    }));

    return controller;
  }

  void _recomputeHasFrame() {
    final has = (_lastWidth ?? 0) > 0 && (_lastHeight ?? 0) > 0;
    if (has && !_hasFrame.value) _hasFrame.add(true);
  }

  /// Applies generous forward/back cache via libmpv, mirroring the just_audio
  /// tuning (minBuffer 50s / forward 60s). Best-effort — properties are only
  /// available on the native (libmpv) backend and are wrapped in try/catch so
  /// a web/unsupported backend degrades gracefully.
  Future<void> _configureBuffering(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('cache', 'yes');
      // Seconds of media to keep buffered ahead — matches Darwin's 60s.
      await platform.setProperty('cache-secs', '60');
      // Forward demuxer cache (in addition to bufferSize above).
      await platform.setProperty('demuxer-max-bytes', '64MiB');
      // Back cache so a small seek-back after a live-edge stall is instant.
      await platform.setProperty('demuxer-max-back-bytes', '32MiB');
      // Fast-start (join speed): begin playback as soon as the decoder has a
      // frame instead of waiting for the cache to fill first. This is libmpv's
      // default, set explicitly to lock the instant-start intent for live TV.
      // Code-verified only — the iOS simulator can't decode video, so this
      // path is not measurable on the test rig.
      await platform.setProperty('cache-pause-initial', 'no');
    } catch (e) {
      debugPrint('VideoPlaybackService: buffering config failed: $e');
    }
  }

  /// Opens [url] and (by default) starts playing. [live] marks the media as a
  /// live stream so no VOD timeline is exposed. [startPosition] seeks a VOD
  /// item after load (used to carry position across a background handoff).
  Future<void> open(
    String url, {
    bool live = false,
    bool autoPlay = true,
    Duration? startPosition,
  }) async {
    await ensureInitialized();
    final player = _player!;
    _live = live;
    _completed.add(false);
    // Reset first-frame tracking for the new media so the watchdog re-arms.
    _lastWidth = null;
    _lastHeight = null;
    _hasFrame.add(false);
    await player.open(Media(url), play: autoPlay);
    // Re-apply volume/mute across media changes (libmpv keeps them, but be safe).
    await player.setVolume(_muted ? 0.0 : _volume * 100.0);
    if (!live && startPosition != null && startPosition > Duration.zero) {
      // Seek after open; libmpv accepts a seek queued right after load.
      await player.seek(startPosition);
    }
  }

  Future<void> play() async => _player?.play();

  Future<void> pause() async => _player?.pause();

  /// Stops playback and clears the current media, but keeps the player and
  /// video texture alive for a fast subsequent [open].
  Future<void> stop() async {
    _completed.add(false);
    await _player?.stop();
  }

  Future<void> seek(Duration position) async => _player?.seek(position);

  /// Sets volume in the 0..1 range (media_kit uses 0..100 internally).
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (!_muted) await _player?.setVolume(_volume * 100.0);
  }

  Future<void> setMute(bool mute) async {
    _muted = mute;
    await _player?.setVolume(mute ? 0.0 : _volume * 100.0);
  }

  /// Fully tears down native resources. After this the service must be
  /// re-created; call [ensureInitialized] again to reuse.
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final player = _player;
    _player = null;
    _controller = null;
    if (player != null) {
      await player.dispose();
    }
    await _position.close();
    await _duration.close();
    await _buffering.close();
    await _playing.close();
    await _completed.close();
    await _error.close();
    await _hasFrame.close();
  }
}
