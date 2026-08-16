import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'video_quality.dart';

/// Wraps the official `video_player` plugin (AVPlayer on iOS, ExoPlayer/Media3
/// on Android) for the app's "video mode": TV channels and video playlist items
/// played with perfect audio+video sync by the native player.
///
/// video_player gives free HLS adaptive-bitrate (ABR) streaming and — crucially
/// — creates NO media session / now-playing entry, so [AppAudioHandler] (backed
/// by audio_service) stays the SINGLE owner of the lock screen, notification,
/// CarPlay and Android Auto. This service only plays pixels + audio and exposes
/// playback streams; it never publishes `MediaItem`/`playbackState`.
///
/// A new [VideoPlayerController] is created per media (video_player controllers
/// are single-URL); [open] disposes the previous one and builds the next. The
/// rendered controller is exposed via [controller] / [controllerStream] so the
/// surface can swap seamlessly — used both across media and for the
/// preload-then-swap manual quality switch (see [setVideoQuality]).
///
/// Background playback is REQUIRED (`allowBackgroundPlayback: true`) for the
/// gapless background handoff in [AppAudioHandler]: the video keeps playing
/// audibly while just_audio spins up muted. `mixWithOthers: false` so it does
/// not duck under other apps.
class VideoPlaybackService {
  VideoPlaybackService();

  VideoPlayerController? _controller;

  bool _live = false;
  bool _muted = false;
  double _volume = 1.0;
  bool _playIntended = false;

  /// The master (adaptive) URL for the CURRENT media — what `Auto` plays and
  /// what the quality parser fetched. Kept so [setVideoQuality] can return to
  /// `Auto` by re-opening it.
  String? _masterUrl;

  /// Monotonic token so a late master-playlist fetch (or a pending quality
  /// swap) belonging to a superseded [open] is ignored.
  int _mediaGeneration = 0;

  /// Guards against re-emitting the same error string repeatedly (video_player
  /// keeps `hasError` set on the value).
  String? _lastError;

  // Seeded so the UI/handler can subscribe before the first [open].
  final BehaviorSubject<Duration> _position =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _duration =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<bool> _buffering = BehaviorSubject<bool>.seeded(false);

  /// The play/pause INTENT (see [isPlaying]) — not the engine's rate flag.
  final BehaviorSubject<bool> _playing = BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<bool> _completed = BehaviorSubject<bool>.seeded(false);
  final PublishSubject<String> _error = PublishSubject<String>();

  /// The active [VideoPlayerController] for the surface's `VideoPlayer` widget,
  /// re-emitted whenever it swaps (new media or manual quality change).
  final BehaviorSubject<VideoPlayerController?> _activeController =
      BehaviorSubject<VideoPlayerController?>.seeded(null);

  /// True once the native player has produced a first video frame for the
  /// CURRENT media (reset on every [open]). Derived from
  /// `controller.value.isInitialized` plus a non-empty [size] — an initialized
  /// controller reporting real pixel dimensions has decoded a frame. Drives the
  /// video→audio fallback watchdog: on a platform/codec that never initializes,
  /// this stays false and the handler hands off to audio-only.
  final BehaviorSubject<bool> _hasFrame = BehaviorSubject<bool>.seeded(false);

  /// Current video pixel dimensions (null until the first frame). Surfaces size
  /// their `AspectRatio` from these.
  final BehaviorSubject<int?> _width = BehaviorSubject<int?>.seeded(null);
  final BehaviorSubject<int?> _height = BehaviorSubject<int?>.seeded(null);

  /// The distinct, pinnable video qualities for the CURRENT media (NOT including
  /// `Auto`), highest resolution first. Empty for a plain media playlist, for a
  /// master with separate audio groups (manual pinning would drop audio — Auto
  /// only), or before the master has been parsed. Reset on every [open].
  final BehaviorSubject<List<VideoQuality>> _qualities =
      BehaviorSubject<List<VideoQuality>>.seeded(const []);

  /// The currently selected quality (`Auto` by default). Drives the picker's
  /// checkmark.
  final BehaviorSubject<VideoQuality> _selectedQuality =
      BehaviorSubject<VideoQuality>.seeded(VideoQuality.auto);

  /// Forward buffer target for a LIVE stream, in seconds (2 minutes).
  ///
  /// With video_player, buffer sizing is owned by the native player (AVPlayer /
  /// ExoPlayer) and is not configurable from Dart — the old libmpv
  /// `cache-secs` / `demuxer-readahead-secs` tuning is gone. This constant is
  /// retained ONLY as the single enforced lock-step link to the radio
  /// (just_audio) pipeline's `FastStartConfig.liveForwardBufferTarget`: the two
  /// live in libraries that must not import each other, so a unit test asserts
  /// their equality. Do not wire it to the engine — it has no engine consumer
  /// anymore.
  @visibleForTesting
  static const int liveForwardBufferSeconds = 120;

  /// How long [open] waits for the native player to report `initialized`.
  ///
  /// Without a bound, a host that accepts the connection and then black-holes
  /// the response leaves `initialize()` pending forever: the surface spins with
  /// no error, no frame, and the video→audio fallback never fires. The timeout
  /// turns that into a normal failure that lands in the catch below.
  @visibleForTesting
  static const Duration initializeTimeout = Duration(seconds: 10);

  /// Upper bound on tearing down a controller that failed to initialize. When
  /// `VideoPlayerPlatform.createWithOptions` itself throws, video_player never
  /// completes its internal `_creatingCompleter`, so `dispose()` awaits it
  /// forever — which would hang [open] and swallow the error.
  static const Duration _disposeTimeout = Duration(seconds: 2);

  // ── Public state ──────────────────────────────────────────────────────────

  /// Whether a controller currently exists (media has been opened).
  bool get isInitialized => _controller != null;

  /// The active video controller for the UI's `VideoPlayer(controller)` widget.
  /// Null until the first [open].
  VideoPlayerController? get controller => _controller;

  /// Emits the active controller whenever it swaps (new media / quality change),
  /// so a surface can rebind its `VideoPlayer` without a black flash.
  Stream<VideoPlayerController?> get controllerStream =>
      _activeController.stream;

  /// True when the current media was opened as a live stream (no VOD timeline).
  /// Drives `isLive` on the lock-screen media item.
  bool get isLive => _live;

  Duration get position => _controller?.value.position ?? Duration.zero;
  Duration get duration => _controller?.value.duration ?? Duration.zero;

  /// Whether playback is ON — the play/pause INTENT, exactly like just_audio's
  /// `player.playing`, and NOT the decoder's momentary rate.
  ///
  /// `VideoPlayerController.value.isPlaying` mirrors the native rate: the
  /// AVFoundation plugin pushes `isPlayingStateUpdate(player.rate > 0)`, so a
  /// live stream that rebuffers (or has not reached `rate == 1` right after
  /// `play()`) reports `isPlaying == false` while the user is very much still
  /// playing. Publishing that as the app's playing flag flipped the transport
  /// button to the "play" glyph while a TV channel was audibly playing, and made
  /// the stall watchdog think nobody intended to play. "Waiting for data" is
  /// reported separately by [isBuffering] — that is what the UI shows as
  /// loading.
  bool get isPlaying => _playIntended;

  /// The engine's momentary rate flag (`rate > 0`), for diagnostics only. UI and
  /// playback-state decisions use [isPlaying] (the intent) instead.
  bool get engineIsPlaying => _controller?.value.isPlaying ?? false;

  bool get isBuffering => _controller?.value.isBuffering ?? false;

  /// Current playback position. For a VOD item this is the elapsed time.
  Stream<Duration> get positionStream => _position.stream;

  /// Total media duration as the native player reports it (VOD length; for a
  /// live stream this is often zero/unknown, in which case the overlay shows the
  /// plain LIVE bar rather than a DVR scrubber).
  Stream<Duration> get durationStream => _duration.stream;

  /// True while the native player is waiting on data.
  Stream<bool> get bufferingStream => _buffering.stream;

  /// True while playback is ON, false when paused/stopped — the play/pause
  /// INTENT (see [isPlaying]), so it never flickers on a rebuffer.
  Stream<bool> get playingStream => _playing.stream;

  /// Emits `true` once when the media reaches its end (VOD auto-advance).
  Stream<bool> get completedStream => _completed.stream;

  /// Emits an error string when playback fails.
  Stream<String> get errorStream => _error.stream;

  /// Emits `true` once the CURRENT media renders a first video frame (reset to
  /// `false` on every [open]). See [_hasFrame].
  Stream<bool> get hasFrameStream => _hasFrame.stream;

  /// Whether the current media has rendered a first video frame yet.
  bool get hasRenderedFrame => _hasFrame.value;

  /// Current video pixel width / height (null before the first frame).
  Stream<int?> get widthStream => _width.stream;
  Stream<int?> get heightStream => _height.stream;
  int? get width => _width.value;
  int? get height => _height.value;

  /// The distinct, pinnable video qualities for the current media (no `Auto`).
  Stream<List<VideoQuality>> get qualitiesStream => _qualities.stream;
  List<VideoQuality> get qualities => _qualities.value;

  /// The currently selected quality.
  Stream<VideoQuality> get selectedQualityStream => _selectedQuality.stream;
  VideoQuality get selectedQuality => _selectedQuality.value;

  VideoPlayerOptions _options() => VideoPlayerOptions(
        // REQUIRED for the gapless background handoff — the video keeps playing
        // audibly while just_audio spins up muted.
        allowBackgroundPlayback: true,
        // Do not duck under other audio; this is a foreground media player.
        mixWithOthers: false,
      );

  // ── Lifecycle ───────────────────────────────────────────────────────────

  /// Opens [url] and (by default) starts playing. [live] marks the media as a
  /// live stream so no VOD timeline is exposed. [startPosition] seeks a VOD item
  /// after load (used to carry position across a background handoff).
  ///
  /// A new [VideoPlayerController] is created for [url]; the previous one is
  /// disposed only AFTER the new controller is initialized and published, so the
  /// surface never renders a disposed controller (no black flash).
  Future<void> open(
    String url, {
    bool live = false,
    bool autoPlay = true,
    Duration? startPosition,
  }) async {
    final generation = ++_mediaGeneration;
    _live = live;
    _setPlayIntent(autoPlay);
    _masterUrl = url;
    _lastError = null;
    // Announce "working on it" immediately: between here and the first frame
    // the engine reports nothing, so without this the surface would show a
    // plain black box with no spinner. Cleared on error/timeout below, and
    // overwritten with the engine's own value by _bind() on success.
    _buffering.add(true);
    // Reset per-media state so the watchdogs re-arm and the picker clears.
    _completed.add(false);
    _hasFrame.add(false);
    _width.add(null);
    _height.add(null);
    _qualities.add(const []);
    _selectedQuality.add(VideoQuality.auto);

    final previous = _controller;

    final next = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: _options(),
    );
    try {
      await next.initialize().timeout(initializeTimeout);
    } catch (e) {
      debugPrint('VideoPlaybackService: initialize failed: $e');
      await _disposeQuietly(next);
      if (generation == _mediaGeneration) {
        // Stop the spinner before the error surfaces, so the UI never shows a
        // spinner spinning next to an error state. Nothing can be playing after
        // a failed load, so the intent drops too.
        _buffering.add(false);
        _setPlayIntent(false);
        _error.add(e.toString());
      }
      return;
    }
    if (generation != _mediaGeneration) {
      // A newer open() superseded this one while we were initializing.
      await _disposeQuietly(next);
      return;
    }

    await next.setVolume(_muted ? 0.0 : _volume);
    if (!live && startPosition != null && startPosition > Duration.zero) {
      await next.seekTo(startPosition);
    }

    _bind(next);
    if (previous != null) await _disposeController(previous);

    if (autoPlay) {
      await next.play();
      await _applyWakelock(true);
    }
    // Parse the master playlist for the quality picker (best-effort, async).
    unawaited(_loadQualities(url, generation));
  }

  Future<void> play() async {
    _setPlayIntent(true);
    await _controller?.play();
    await _applyWakelock(true);
  }

  Future<void> pause() async {
    _setPlayIntent(false);
    await _controller?.pause();
    await _applyWakelock(false);
  }

  /// Stops playback (pauses and releases the wakelock) while KEEPING the
  /// controller and its last frame alive, so a handoff/fallback leaves a still
  /// picture rather than a black flash. [dispose] fully releases resources; the
  /// next [open] replaces the controller.
  Future<void> stop() async {
    _completed.add(false);
    _setPlayIntent(false);
    await _controller?.pause();
    await _applyWakelock(false);
  }

  Future<void> seek(Duration position) async =>
      _controller?.seekTo(position);

  /// Sets volume in the 0..1 range.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    if (!_muted) await _controller?.setVolume(_volume);
  }

  Future<void> setMute(bool mute) async {
    _muted = mute;
    await _controller?.setVolume(mute ? 0.0 : _volume);
  }

  // ── Quality (Auto ABR + preload-then-swap manual pin) ─────────────────────

  /// Fetches and parses the master playlist [url] to populate the quality
  /// picker. Best-effort: any failure (non-HLS, network error, media playlist,
  /// audio groups present) simply leaves the picker at "Auto only".
  Future<void> _loadQualities(String url, int generation) async {
    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      if (generation != _mediaGeneration) return;
      if (resp.statusCode != 200) return;
      final body = resp.body;
      if (!body.contains('#EXTM3U')) return; // not an HLS playlist
      final info = parseHlsMaster(body, Uri.parse(url));
      if (generation != _mediaGeneration) return;
      // Separate audio groups → a variant-only URL would be video-only, so
      // pinning would drop audio. Keep Auto only in that case.
      if (info.hasAudioGroups) return;
      if (info.qualities.length < 2) return; // nothing worth a picker
      _qualities.add(info.qualities);
    } catch (e) {
      debugPrint('VideoPlaybackService: quality parse skipped: $e');
    }
  }

  /// Selects [quality] for output.
  ///
  /// `Auto` re-opens the MASTER url (native ABR). A concrete quality does a
  /// preload-then-swap: a SECOND controller is created on the variant URL and
  /// fully initialized (for VOD, seeked to the current position) while the OLD
  /// controller keeps playing; only then is the rendered controller atomically
  /// swapped and the old one disposed — no black frame, no audible gap. The new
  /// controller is prepared MUTED so the brief overlap is never double-audio;
  /// it is unmuted the instant it becomes the active source.
  Future<void> setVideoQuality(VideoQuality quality) async {
    final current = _controller;
    if (current == null) return;
    final targetUrl = quality.isAuto ? _masterUrl : quality.url;
    if (targetUrl == null) return;
    if (quality.id == _selectedQuality.value.id) return;

    final generation = _mediaGeneration; // pin to the current media
    final resumePosition = current.value.position;
    final wasPlaying = current.value.isPlaying || _playIntended;

    final next = VideoPlayerController.networkUrl(
      Uri.parse(targetUrl),
      videoPlayerOptions: _options(),
    );
    try {
      await next.setVolume(0.0); // muted preload — no double audio in overlap
      await next.initialize();
      if (generation != _mediaGeneration) {
        await next.dispose();
        return; // media changed mid-swap
      }
      if (!_live && resumePosition > Duration.zero) {
        await next.seekTo(resumePosition);
      }
      if (wasPlaying) await next.play();
    } catch (e) {
      debugPrint('VideoPlaybackService: quality swap init failed: $e');
      await _disposeQuietly(next);
      return; // keep the old controller playing untouched
    }

    // Atomic swap: bind + publish the new controller, then unmute it and tear
    // down the old one.
    _bind(next);
    _selectedQuality.add(quality);
    await next.setVolume(_muted ? 0.0 : _volume);
    await _disposeController(current);
  }

  // ── Internal wiring ───────────────────────────────────────────────────────

  /// Makes [c] the active controller: attaches the value listener, publishes it
  /// on [controllerStream] and re-emits its current state onto the streams.
  void _bind(VideoPlayerController c) {
    _controller = c;
    _lastError = null;
    // The listener is removed when the controller is disposed (in
    // [_disposeController]/[dispose]); until then a stale listener is a no-op
    // because [_onValue] guards on identity with the active controller.
    c.addListener(() => _onValue(c));
    _activeController.add(c);
    _onValue(c); // emit initial state (already initialized here)
  }

  /// Single writer for the play/pause intent and its stream. Emits only on a
  /// real change, so the handler re-broadcasts `playbackState` on transitions
  /// rather than on every engine tick.
  void _setPlayIntent(bool playing) {
    _playIntended = playing;
    if (_playing.value != playing) _playing.add(playing);
  }

  void _onValue(VideoPlayerController c) {
    if (!identical(c, _controller)) return; // stale listener during a swap
    final v = c.value;
    _position.add(v.position);
    _duration.add(v.duration);
    _buffering.add(v.isBuffering);

    final size = v.size;
    final w = size.width.round();
    final h = size.height.round();
    if (v.isInitialized && w > 0 && h > 0) {
      if (_width.value != w) _width.add(w);
      if (_height.value != h) _height.add(h);
      if (!_hasFrame.value) _hasFrame.add(true);
    }

    // Reaching the end (VOD) or failing outright genuinely ends playback — the
    // only two engine events that legitimately clear the play intent.
    if (v.isCompleted && !_completed.value) {
      _setPlayIntent(false);
      _completed.add(true);
    }

    if (v.hasError) {
      final desc = v.errorDescription ?? 'video error';
      if (desc != _lastError) {
        _setPlayIntent(false);
        _lastError = desc;
        debugPrint('VideoPlaybackService: player error: $desc');
        _error.add(desc);
      }
    }
  }

  /// Tears down a controller that never became the active one, without ever
  /// blocking the caller: a controller whose native creation threw leaves
  /// video_player's `_creatingCompleter` pending, so its `dispose()` would
  /// never return. Bounded by [_disposeTimeout]; timeouts and errors are
  /// ignored on purpose — the native side is already gone or unreachable.
  Future<void> _disposeQuietly(VideoPlayerController c) async {
    try {
      await c.dispose().timeout(_disposeTimeout);
    } catch (e) {
      debugPrint('VideoPlaybackService: dispose of a failed controller '
          'did not complete: $e');
    }
  }

  Future<void> _disposeController(VideoPlayerController c) async {
    // Detach our listener only if it belongs to c (the active listener may have
    // already been reassigned to the replacement controller by _bind).
    try {
      await c.pause();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  Future<void> _applyWakelock(bool enable) async {
    try {
      if (enable) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      // Wakelock is a nicety; never let it break playback.
      debugPrint('VideoPlaybackService: wakelock toggle failed: $e');
    }
  }

  /// Fully tears down native resources. After this the service must be
  /// re-created; a subsequent [open] rebuilds a controller.
  Future<void> dispose() async {
    _mediaGeneration++;
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        await c.dispose();
      } catch (_) {}
    }
    await _applyWakelock(false);
    await _position.close();
    await _duration.close();
    await _buffering.close();
    await _playing.close();
    await _completed.close();
    await _error.close();
    await _activeController.close();
    await _hasFrame.close();
    await _width.close();
    await _height.close();
    await _qualities.close();
    await _selectedQuality.close();
  }
}
