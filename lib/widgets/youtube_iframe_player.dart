import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../services/playlist_controller.dart';
import '../tv/tv_platform.dart';
import '../types/playlist_item.dart';
import 'player_video_surface.dart';
import 'video_overlay_controls.dart';

/// Whether a fullscreen transition may touch the platform's orientation and
/// system bars.
///
/// Handhelds: yes — fullscreen means landscape + immersive, and leaving it
/// restores portrait. TV and desktop: never. Those windows have no orientation
/// to pin, and pinning one squeezes the whole large-screen shell into a narrow
/// column (the bug that hit Android TV when leaving an embedded YouTube item).
bool shouldApplyFullscreenSystemChrome({required bool isTv}) => !isTv;

/// Renders a playlist YouTube item inline via `youtube_player_iframe` and wires
/// it back to the [PlaylistController] contract:
///   - end-of-video / end-of-playlist → [PlaylistController.notifyYoutubeItemEnded]
///   - player error   → [PlaylistController.notifyYoutubeItemError]
///   - position tick  → [PlaylistController.notifyYoutubePosition]
///   - play/paused    → [PlaylistController.notifyYoutubePlaying] (so the mini
///     player / notification reflect it)
///   - honors [PlaylistController.youtubeShouldPlay] (the single play/pause
///     command channel, driven by the handler) and [PlaylistController.youtubeSeek].
///
/// A [PlaylistItemType.youtubePlaylist] item loads the WHOLE YouTube playlist
/// (`loadPlaylist`); inner-video transitions do NOT advance the app playlist —
/// only the last video finishing does.
///
/// The widget must stay mounted while the mini player is collapsed so the
/// iframe keeps playing; the full player keeps it in the tree for exactly that
/// reason.
///
/// Controls and fullscreen are entirely Flutter's, on every platform: the
/// iframe is loaded with `controls=0`, and the picture is covered by the app's
/// own [VideoOverlayControls] (or, on TV, the shell's D-pad chrome) supplied
/// through [YoutubePlayer.controlsBuilder]. That parameter is the ONLY correct
/// place for them since the package hoists the WebView into an `OverlayPortal`
/// that floats above the page — a widget merely stacked over this one paints
/// and hit-tests BEHIND the picture.
class YoutubeIframePlayer extends StatefulWidget {
  const YoutubeIframePlayer({
    super.key,
    required this.item,
    required this.controller,
    this.aspectRatio = 16 / 9,
    this.showInlineOverlay = true,
    this.overlayBuilder,
  });

  /// The YouTube (video or playlist) item to render.
  final PlaylistItem item;

  /// The engine's playlist controller (contract callbacks + command streams).
  final PlaylistController controller;

  final double aspectRatio;

  /// Whether to draw the app's touch controls ([VideoOverlayControls]) over
  /// the picture. The phone wants them; the TV shell composes its own D-pad
  /// chrome instead, so it passes false and gets a bare, shielded surface.
  final bool showInlineOverlay;

  /// Chrome drawn INSIDE the player's own controls layer, above the picture.
  ///
  /// The TV shell passes its D-pad chrome here rather than stacking it over
  /// this widget, for the reason in the class doc: the WebView lives in an
  /// `OverlayPortal` above the page, so anything stacked outside ends up
  /// behind it. When set, the touch controls are not built — the supplied
  /// chrome owns the surface.
  final WidgetBuilder? overlayBuilder;

  @override
  State<YoutubeIframePlayer> createState() => _YoutubeIframePlayerState();
}

class _YoutubeIframePlayerState extends State<YoutubeIframePlayer> {
  late final YoutubePlayerController _yt;
  StreamSubscription<YoutubePlayerValue>? _stateSub;
  StreamSubscription<YoutubeVideoState>? _positionSub;
  StreamSubscription<bool>? _shouldPlaySub;
  StreamSubscription<Duration>? _seekSub;
  StreamSubscription<void>? _fullscreenReqSub;

  int? _loadedItemId;
  bool _endedReported = false;
  Duration _duration = Duration.zero;
  bool _isFullscreen = false;

  // Reactive streams feeding OUR overlay ([VideoOverlayControls]) drawn over the
  // shielded iframe, so YouTube items get the exact same tap-to-reveal scrubber
  // + fullscreen affordance as media_kit video. Fed from [_onValue]/[_onPosition].
  final BehaviorSubject<bool> _playingSubject =
      BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<bool> _bufferingSubject =
      BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<Duration> _positionSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _durationSubject =
      BehaviorSubject<Duration>.seeded(Duration.zero);

  /// True once the current load has reached the iframe (any real playerState).
  /// Until then play/pause commands are held back: `playVideo()` on a player
  /// with no content makes YouTube fire ERROR 2 (invalidParam), which would be
  /// misread as the ITEM failing (verified against the real IFrame API).
  bool _contentStarted = false;

  /// Latest desired play/pause state, applied once the content starts.
  bool _pendingShouldPlay = true;

  /// Last error VALUE seen. [YoutubePlayerValue] keeps the error sticky across
  /// later state updates, so only a transition (none→e / e1→e2) is a genuinely
  /// new error worth reporting.
  YoutubeError _lastSeenError = YoutubeError.none;

  bool get _isPlaylist =>
      widget.item.type == PlaylistItemType.youtubePlaylist;

  @override
  void initState() {
    super.initState();
    _yt = YoutubePlayerController(
      params: const YoutubePlayerParams(
        // `controls=0`: the iframe draws NO chrome of its own, on any
        // platform. Every control the user sees is a Flutter widget in the
        // player's own controls layer (see [_buildControls]) — the same
        // overlay the rest of the app's video uses, and the only kind a TV
        // remote can reach at all (a WebView cannot receive D-pad input).
        //
        // Leaving YouTube's chrome on is not a free "bonus": it is drawn
        // INSIDE the picture, under our translucent overlay, and YouTube
        // raises it by itself whenever the video pauses — two stacked play
        // buttons, only one of them reachable.
        showControls: false,
        showFullscreenButton: false,
        mute: false,
        loop: false,
        enableCaption: false,
        // youtube-nocookie.com host; avoids setting tracking cookies.
        privacyEnhancedMode: true,
        // Keep the related-video grid to the same channel where possible.
        strictRelatedVideos: true,
        playsInline: true,
      ),
    );

    _stateSub = _yt.stream.listen(_onValue);
    _positionSub = _yt.videoStateStream.listen(_onPosition);
    _shouldPlaySub =
        widget.controller.youtubeShouldPlay.stream.listen(_onShouldPlay);
    _seekSub = widget.controller.youtubeSeek.stream.listen(_onSeek);
    _fullscreenReqSub = widget.controller.youtubeFullscreenRequests.stream
        .listen((_) => _yt.enterFullScreen());
    // The package renders fullscreen itself by re-positioning the SAME
    // WebView (no remount, playback continues); we only own the system
    // chrome — landscape + immersive on enter, portrait restored on exit.
    _yt.setFullScreenListener(_onFullscreenChanged);

    _loadItem(widget.item);
  }

  /// Applies the platform chrome for the player's fullscreen transitions:
  /// landscape + immersive in, portrait restored out — through the very same
  /// helpers the `video_player` fullscreen route uses, so both video kinds
  /// leave the app in identical shape.
  ///
  /// The package delivers this as a plain callback, NOT as a rebuild, so the
  /// flag is flipped inside [setState]: it is what [dispose] reads to undo the
  /// chrome if the player is torn down while still fullscreen.
  void _onFullscreenChanged(bool fullscreen) {
    if (_isFullscreen == fullscreen) return;
    if (mounted) {
      setState(() => _isFullscreen = fullscreen);
    } else {
      _isFullscreen = fullscreen;
    }
    // Orientation and system bars are a HANDHELD concern. A TV (or desktop)
    // window has no orientation to set: pinning it portrait squeezes the whole
    // large-screen shell into a narrow column — which is exactly what leaving
    // an embedded YouTube item used to do on Android TV.
    if (!shouldApplyFullscreenSystemChrome(isTv: TvPlatform.isTV)) return;
    unawaited(fullscreen
        ? enterVideoFullscreenChrome()
        : exitVideoFullscreenChrome());
  }

  @override
  void didUpdateWidget(covariant YoutubeIframePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.id != oldWidget.item.id) {
      _loadItem(widget.item);
    }
  }

  void _loadItem(PlaylistItem item) {
    if (_loadedItemId == item.id) return;
    _loadedItemId = item.id;
    _endedReported = false;
    _duration = Duration.zero;
    // Reset the overlay's scrubber for the new item (fresh position/duration).
    _durationSubject.add(Duration.zero);
    _positionSubject.add(Duration.zero);
    _contentStarted = false;
    // Clear the sticky error from any previous item so this item's error
    // detection starts fresh (see [_lastSeenError]).
    _lastSeenError = YoutubeError.none;
    _yt.update(error: YoutubeError.none);

    if (item.type == PlaylistItemType.youtubePlaylist) {
      final listId = youtubePlaylistIdFromUrl(item.url);
      if (listId == null || listId.isEmpty) {
        widget.controller.notifyYoutubeItemError(itemId: item.id);
        return;
      }
      unawaited(_loadYoutubePlaylist(listId, item.id));
      return;
    }

    final videoId =
        YoutubePlayerController.convertUrlToId(item.url) ?? item.url;
    if (videoId.isEmpty) {
      widget.controller.notifyYoutubeItemError(itemId: item.id);
      return;
    }
    _yt.loadVideoById(videoId: videoId);
  }

  /// Loads a whole YouTube playlist by [listId].
  ///
  /// The bundled `loadPlaylist` serializes `list` as a JS **array**, but the
  /// IFrame API requires the playlist id as a **string** when `listType` is
  /// `playlist` — so the wrapper's call silently no-ops and nothing plays
  /// (the reported bug). We gate on the player being ready via a benign
  /// [YoutubePlayerController.setLoop] (its eval awaits the `Ready` event) and
  /// then issue the correctly shaped call straight to the iframe.
  Future<void> _loadYoutubePlaylist(String listId, int itemId) async {
    try {
      await _yt.setLoop(loopPlaylists: false);
      // Bail if the item advanced while we were waiting for readiness.
      if (!mounted || _loadedItemId != itemId) return;
      await _runPlaylistLoad(listId);
    } catch (e) {
      debugPrint('YoutubeIframePlayer: playlist load failed: $e');
      if (mounted) widget.controller.notifyYoutubeItemError(itemId: itemId);
    }
  }

  /// Issues the correctly shaped `loadPlaylist` JS (`list` as a string) with
  /// an optional starting [index]/[startSeconds] (used by the chrome swap).
  Future<void> _runPlaylistLoad(
    String listId, {
    int index = 0,
    double startSeconds = 0,
  }) {
    final escaped = listId.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    return _yt.webViewController.runJavaScript(
      "player.loadPlaylist({list: '$escaped', listType: 'playlist', "
      'index: $index, startSeconds: $startSeconds});',
    );
  }

  void _onValue(YoutubePlayerValue value) {
    if (kDebugMode) {
      debugPrint('YoutubeIframePlayer: state=${value.playerState.name} '
          'error=${value.error.name} video=${value.metaData.videoId}');
    }
    final d = value.metaData.duration;
    if (d > Duration.zero) {
      _duration = d;
      _durationSubject.add(d);
    }
    // Mirror playing/buffering to the overlay (kept independent of the app
    // playbackState so the scrubber's spinner/visibility reacts instantly).
    _playingSubject.add(value.playerState == PlayerState.playing);
    _bufferingSubject.add(value.playerState == PlayerState.buffering);

    // First real state → the load reached the iframe; release any held
    // play/pause command (the load itself autoplays, so only a pending pause
    // needs applying).
    if (!_contentStarted && value.playerState != PlayerState.unknown) {
      _contentStarted = true;
      if (!_pendingShouldPlay) _yt.pauseVideo();
    }

    switch (value.playerState) {
      case PlayerState.playing:
        widget.controller.notifyYoutubePlaying(true, itemId: widget.item.id);
        break;
      case PlayerState.paused:
      case PlayerState.cued:
        widget.controller.notifyYoutubePlaying(false, itemId: widget.item.id);
        break;
      case PlayerState.ended:
        _onEnded();
        break;
      case PlayerState.unStarted:
      case PlayerState.buffering:
      case PlayerState.unknown:
        break;
    }

    // Report only error TRANSITIONS — the value keeps the last error sticky
    // across unrelated state updates, which would otherwise re-fail the item.
    final previousError = _lastSeenError;
    _lastSeenError = value.error;
    if (value.error != YoutubeError.none && value.error != previousError) {
      widget.controller.notifyYoutubeItemError(itemId: widget.item.id);
    }
  }

  /// End-of-media handling. For a single video, any `ended` finishes the item.
  /// For a whole playlist, `ended` fires after EVERY inner video — only the
  /// last one finishing the playlist should advance the app playlist.
  void _onEnded() {
    if (_endedReported) return;
    if (!_isPlaylist) {
      _endedReported = true;
      widget.controller.notifyYoutubeItemEnded(itemId: widget.item.id);
      return;
    }
    unawaited(_maybeFinishPlaylist());
  }

  Future<void> _maybeFinishPlaylist() async {
    try {
      final index = await _yt.playlistIndex;
      final videos = await _yt.playlist;
      final total = videos.length;
      // Last (or unknown-length) video ended → the whole playlist is done.
      if (total <= 0 || index >= total - 1) {
        if (_endedReported) return;
        _endedReported = true;
        widget.controller.notifyYoutubeItemEnded(itemId: widget.item.id);
      }
      // Otherwise an inner video ended — the iframe auto-advances; ignore.
    } catch (_) {
      // Couldn't determine playlist position — advance rather than get stuck.
      if (_endedReported) return;
      _endedReported = true;
      widget.controller.notifyYoutubeItemEnded(itemId: widget.item.id);
    }
  }

  void _onPosition(YoutubeVideoState state) {
    _positionSubject.add(state.position);
    widget.controller
        .notifyYoutubePosition(state.position, _duration, itemId: widget.item.id);
  }

  void _onShouldPlay(bool shouldPlay) {
    _pendingShouldPlay = shouldPlay;
    // Hold commands until the load reaches the iframe — playVideo() on a
    // contentless player triggers YouTube ERROR 2 (see [_contentStarted]).
    if (!_contentStarted) return;
    if (shouldPlay) {
      _yt.playVideo();
    } else {
      _yt.pauseVideo();
    }
  }

  void _onSeek(Duration to) {
    _yt.seekTo(seconds: to.inMilliseconds / 1000.0, allowSeekAhead: true);
  }

  /// Seek from OUR overlay's scrubber. Seeks the current video directly (this
  /// is intra-video scrubbing, distinct from app-playlist navigation), and
  /// optimistically advances the local position so the thumb doesn't snap back
  /// before the next position tick.
  void _onOverlaySeek(Duration to) {
    _yt.seekTo(seconds: to.inMilliseconds / 1000.0, allowSeekAhead: true);
    _positionSubject.add(to);
  }

  @override
  void dispose() {
    // Defensively restore portrait if the player is torn down while fullscreen
    // (e.g. the item advances mid-fullscreen) so the app never gets stuck
    // landscape / immersive.
    if (_isFullscreen &&
        shouldApplyFullscreenSystemChrome(isTv: TvPlatform.isTV)) {
      unawaited(exitVideoFullscreenChrome());
    }
    _stateSub?.cancel();
    _positionSub?.cancel();
    _shouldPlaySub?.cancel();
    _seekSub?.cancel();
    _fullscreenReqSub?.cancel();
    _playingSubject.close();
    _bufferingSubject.close();
    _positionSubject.close();
    _durationSubject.close();
    _yt.close();
    super.dispose();
  }

  /// Enters or leaves fullscreen — the single entry point every affordance
  /// (our corner button, the pinch gesture, the vertical flick, the external
  /// transport button) goes through.
  void _toggleFullscreen() => _yt.toggleFullScreen();

  /// Acts on a vertical flick over the player: up enters fullscreen, down
  /// leaves it (the gesture YouTube's own app uses).
  void _onFlick(YoutubeFlickIntent intent) {
    switch (intent) {
      case YoutubeFlickIntent.enter:
        _yt.enterFullScreen();
      case YoutubeFlickIntent.exit:
        _yt.exitFullScreen();
      case YoutubeFlickIntent.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return YoutubePlayer(
      controller: _yt,
      aspectRatio: widget.aspectRatio,
      // Fullscreen is pure Flutter here (the package re-positions the SAME
      // WebView through an OverlayPortal — no reload, so playback is never
      // interrupted, and the behaviour is identical on iOS, Android and
      // Android TV). Everything drawn over the picture comes from
      // [_buildControls].
      controlsBuilder: _buildControls,
      // The package's own drag-to-fullscreen listens BELOW the controls layer,
      // where a pointer never reaches once our overlay covers the surface. We
      // run the same gesture ourselves, above it — see [YoutubeFlickDetector].
      enableFullScreenOnVerticalDrag: false,
      // Rotating a handheld into landscape is a fullscreen request; a TV window
      // is landscape from the moment it opens and must not be read as one.
      autoFullScreen: !TvPlatform.isTV,
    );
  }

  /// Builds the layer the package draws on top of the WebView — inline AND in
  /// fullscreen, in both cases inside the player's own overlay, which is the
  /// only place a widget is guaranteed to sit above the picture.
  Widget _buildControls(BuildContext context, bool isFullscreen) {
    final overlayBuilder = widget.overlayBuilder;
    if (overlayBuilder != null) {
      // TV / desktop: the shell composes its own D-pad chrome. The shield
      // underneath keeps a stray touch from reaching the WebView.
      return Stack(
        fit: StackFit.expand,
        children: [
          const AbsorbPointer(child: SizedBox.expand()),
          overlayBuilder(context),
        ],
      );
    }
    if (!widget.showInlineOverlay) {
      return const AbsorbPointer(child: SizedBox.expand());
    }
    return YoutubeFlickDetector(
      isFullscreen: isFullscreen,
      onFlick: _onFlick,
      child: VideoOverlayControls(
        playingStream: _playingSubject.stream,
        initialPlaying: _playingSubject.value,
        bufferingStream: _bufferingSubject.stream,
        initialBuffering: _bufferingSubject.value,
        positionStream: _positionSubject.stream,
        initialPosition: _positionSubject.value,
        durationStream: _durationSubject.stream,
        initialDuration: _durationSubject.value,
        // Enable the scrubber immediately from the item's known length,
        // before the iframe reports its own duration.
        fallbackDuration: widget.item.durationSeconds != null
            ? Duration(seconds: widget.item.durationSeconds!)
            : null,
        title: widget.item.title,
        isLive: false,
        isFullscreen: isFullscreen,
        // Route play/pause through the handler so the mini player /
        // notification stay the single source of truth.
        onPlay: widget.controller.resume,
        onPause: widget.controller.pause,
        // Skipping belongs to the fullscreen layout only: inline, the
        // playlist transport already sits below the video.
        onPrevious: isFullscreen
            ? () => unawaited(widget.controller.skipToPrevious())
            : null,
        onNext: isFullscreen
            ? () => unawaited(widget.controller.skipToNext())
            : null,
        onSeek: _onOverlaySeek,
        onToggleFullscreen: _toggleFullscreen,
      ),
    );
  }
}

/// What a vertical flick over the player asks fullscreen to do.
enum YoutubeFlickIntent { enter, exit, none }

/// Minimum flick speed, in logical pixels per second, before a vertical swipe
/// counts as a fullscreen gesture. Same threshold the package uses for its own
/// (unreachable, see [YoutubeIframePlayer]) drag handler, so the gesture feels
/// exactly as it does in other apps built on it.
const double kYoutubeFlickVelocity = 300;

/// Minimum travel, in logical pixels, before a vertical swipe counts at all —
/// keeps a fast, sloppy tap from being read as a flick.
const double kYoutubeFlickDistance = 24;

/// Reads a pointer's travel as a fullscreen intent. Pure, so the whole gesture
/// rule is unit-testable without a WebView or a gesture arena.
///
/// A flick counts only when it is mostly vertical, long enough
/// ([kYoutubeFlickDistance]) and fast enough ([kYoutubeFlickVelocity]) — a slow
/// drag is somebody moving their finger, not asking for anything. Up enters
/// fullscreen, down leaves it; a flick that asks for the state the player is
/// already in is [YoutubeFlickIntent.none].
YoutubeFlickIntent youtubeFlickIntent({
  required Offset travel,
  required Duration elapsed,
  required bool isFullscreen,
}) {
  final micros = elapsed.inMicroseconds;
  if (micros <= 0) return YoutubeFlickIntent.none;
  if (travel.dy.abs() <= travel.dx.abs()) return YoutubeFlickIntent.none;
  if (travel.dy.abs() < kYoutubeFlickDistance) return YoutubeFlickIntent.none;
  final velocity = travel.dy.abs() / (micros / Duration.microsecondsPerSecond);
  if (velocity < kYoutubeFlickVelocity) return YoutubeFlickIntent.none;
  final wantsFullscreen = travel.dy.isNegative; // upward flick
  if (wantsFullscreen == isFullscreen) return YoutubeFlickIntent.none;
  return wantsFullscreen ? YoutubeFlickIntent.enter : YoutubeFlickIntent.exit;
}

/// Turns a vertical flick anywhere over the player into a fullscreen intent.
///
/// Watches RAW pointers through a [Listener] rather than a drag recognizer:
/// entering the gesture arena would take vertical drags away from the
/// surrounding scroll view (and from the panel the player lives in), so a slow
/// scroll started on the video would stop scrolling the page. Observing instead
/// leaves every other gesture — taps, double-taps, the scrubber drag, the pinch
/// — exactly as it was, which is the same trick [VideoOverlayControls] uses for
/// pinch-to-fullscreen.
class YoutubeFlickDetector extends StatefulWidget {
  const YoutubeFlickDetector({
    super.key,
    required this.isFullscreen,
    required this.onFlick,
    required this.child,
  });

  /// Whether the player is currently fullscreen — decides which direction is
  /// meaningful.
  final bool isFullscreen;

  /// Called with the recognised intent (never [YoutubeFlickIntent.none]).
  final ValueChanged<YoutubeFlickIntent> onFlick;

  final Widget child;

  @override
  State<YoutubeFlickDetector> createState() => _YoutubeFlickDetectorState();
}

class _YoutubeFlickDetectorState extends State<YoutubeFlickDetector> {
  int? _pointer;
  Offset _origin = Offset.zero;
  Duration _startedAt = Duration.zero;

  void _onDown(PointerDownEvent event) {
    if (_pointer != null) {
      // A second finger landed: this is a pinch, not a flick.
      _pointer = null;
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _startedAt = event.timeStamp;
  }

  void _onUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    final intent = youtubeFlickIntent(
      travel: event.position - _origin,
      elapsed: event.timeStamp - _startedAt,
      isFullscreen: widget.isFullscreen,
    );
    if (intent != YoutubeFlickIntent.none) widget.onFlick(intent);
  }

  void _onCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _pointer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }
}
