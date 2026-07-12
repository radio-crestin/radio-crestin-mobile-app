import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../services/playlist_controller.dart';
import '../types/playlist_item.dart';

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
class YoutubeIframePlayer extends StatefulWidget {
  const YoutubeIframePlayer({
    super.key,
    required this.item,
    required this.controller,
    this.aspectRatio = 16 / 9,
  });

  /// The YouTube (video or playlist) item to render.
  final PlaylistItem item;

  /// The engine's playlist controller (contract callbacks + command streams).
  final PlaylistController controller;

  final double aspectRatio;

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
        // Native controls stay ENABLED so fullscreen has YouTube's own chrome
        // without ever reloading the iframe (a reload interrupts playback —
        // the "stuck on fullscreen" bug). Inline, a transparent tap shield
        // (see [build]) keeps the surface effectively chromeless: the chrome
        // can only flash briefly on load, never summoned by touch.
        showControls: true,
        // Gives fullscreen chrome its exit button; the package routes its
        // clicks back through the fullscreen listener.
        showFullscreenButton: true,
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
  /// landscape + immersive in, portrait restored out. The iframe itself is
  /// untouched — its native controls handle fullscreen interaction.
  void _onFullscreenChanged(bool fullscreen) {
    if (_isFullscreen == fullscreen) return;
    _isFullscreen = fullscreen;
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      _restorePortraitChrome();
    }
  }

  /// Restores portrait orientation and the normal (edge-to-edge) system UI.
  void _restorePortraitChrome() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
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
    if (d > Duration.zero) _duration = d;

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

  @override
  void dispose() {
    // Defensively restore portrait if the player is torn down while fullscreen
    // (e.g. the item advances mid-fullscreen) so the app never gets stuck
    // landscape / immersive.
    if (_isFullscreen) _restorePortraitChrome();
    _stateSub?.cancel();
    _positionSub?.cancel();
    _shouldPlaySub?.cancel();
    _seekSub?.cancel();
    _fullscreenReqSub?.cancel();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Inline, a transparent shield over the webview swallows every tap so
    // YouTube's chrome is never summoned — the surface reads as chromeless
    // and all controls (prev, play/pause, next, fullscreen) live OUTSIDE the
    // player, linked through the PlaylistController channels. In fullscreen
    // the shield lifts: the user interacts with YouTube's own controls, plus
    // a minimal prev/next pair at the screen edges for app-playlist
    // navigation (the native chrome can't do that). The same WebView instance
    // persists across the transition (the package only re-positions it), so
    // playback is never interrupted.
    return YoutubePlayer(
      controller: _yt,
      aspectRatio: widget.aspectRatio,
      controlsBuilder: (context, isFullscreen) => isFullscreen
          ? _FullscreenEdgeSkips(
              onPrevious: () => unawaited(widget.controller.skipToPrevious()),
              onNext: () => unawaited(widget.controller.skipToNext()),
            )
          : const AbsorbPointer(child: SizedBox.expand()),
    );
  }
}

/// Minimal prev/next pair pinned to the screen edges in YouTube fullscreen.
///
/// Sits above the iframe but only claims hits on the two small buttons, so
/// YouTube's native chrome stays fully interactive. Dims to a subtle state
/// after a few seconds (and re-brightens on use) instead of hiding entirely —
/// fully hidden buttons would be unreachable, since surface taps belong to
/// the native chrome.
class _FullscreenEdgeSkips extends StatefulWidget {
  const _FullscreenEdgeSkips({
    required this.onPrevious,
    required this.onNext,
  });

  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  State<_FullscreenEdgeSkips> createState() => _FullscreenEdgeSkipsState();
}

class _FullscreenEdgeSkipsState extends State<_FullscreenEdgeSkips> {
  bool _dimmed = false;
  Timer? _dimTimer;

  static const Duration _dimDelay = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _scheduleDim();
  }

  @override
  void dispose() {
    _dimTimer?.cancel();
    super.dispose();
  }

  void _scheduleDim() {
    _dimTimer?.cancel();
    _dimTimer = Timer(_dimDelay, () {
      if (mounted) setState(() => _dimmed = true);
    });
  }

  void _onTap(VoidCallback action) {
    setState(() => _dimmed = false);
    _scheduleDim();
    action();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: _EdgeSkipButton(
              icon: Icons.skip_previous_rounded,
              dimmed: _dimmed,
              onTap: () => _onTap(widget.onPrevious),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _EdgeSkipButton(
              icon: Icons.skip_next_rounded,
              dimmed: _dimmed,
              onTap: () => _onTap(widget.onNext),
            ),
          ),
        ),
      ],
    );
  }
}

class _EdgeSkipButton extends StatelessWidget {
  const _EdgeSkipButton({
    required this.icon,
    required this.dimmed,
    required this.onTap,
  });

  final IconData icon;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      opacity: dimmed ? 0.35 : 1.0,
      child: Material(
        color: Colors.black.withValues(alpha: 0.38),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
      ),
    );
  }
}
