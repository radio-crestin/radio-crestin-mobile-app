import 'dart:async';

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

  /// Content currently loaded, kept so the fullscreen chrome swap (which
  /// reloads the iframe) can restore it at the same position.
  String? _currentVideoId;
  String? _currentListId;

  bool get _isPlaylist =>
      widget.item.type == PlaylistItemType.youtubePlaylist;

  @override
  void initState() {
    super.initState();
    _yt = YoutubePlayerController(params: _paramsFor(nativeControls: false));

    _stateSub = _yt.stream.listen(_onValue);
    _positionSub = _yt.videoStateStream.listen(_onPosition);
    _shouldPlaySub =
        widget.controller.youtubeShouldPlay.stream.listen(_onShouldPlay);
    _seekSub = widget.controller.youtubeSeek.stream.listen(_onSeek);
    _fullscreenReqSub = widget.controller.youtubeFullscreenRequests.stream
        .listen((_) => _yt.enterFullScreen());
    // The package renders fullscreen itself (an overlay); we own the system
    // chrome (landscape+immersive) and the controls swap: chromeless inline,
    // YouTube's own controls in fullscreen.
    _yt.setFullScreenListener(_onFullscreenChanged);

    _loadItem(widget.item);
  }

  /// Player params for the two chrome states. Inline is chromeless (all
  /// buttons live in the app's UI); fullscreen shows YouTube's own controls —
  /// including its exit-fullscreen button, which the package detects and
  /// routes back to [_onFullscreenChanged].
  static YoutubePlayerParams _paramsFor({required bool nativeControls}) {
    return YoutubePlayerParams(
      showControls: nativeControls,
      showFullscreenButton: nativeControls,
      mute: false,
      loop: false,
      enableCaption: false,
      // youtube-nocookie.com host; avoids setting tracking cookies.
      privacyEnhancedMode: true,
      // Keep the related-video grid to the same channel where possible.
      strictRelatedVideos: true,
      playsInline: true,
    );
  }

  /// Applies the platform chrome for the player's fullscreen transitions
  /// (landscape + immersive in, portrait restored out) and swaps the iframe's
  /// own chrome: native YouTube controls in fullscreen, chromeless inline.
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
    unawaited(_swapIframeChrome(nativeControls: fullscreen));
  }

  /// Reloads the iframe with [nativeControls] on/off, restoring the same
  /// content at the same position.
  ///
  /// The IFrame API fixes `controls` at embed time — it cannot be toggled on a
  /// live player — so the only reliable swap is a reload: capture
  /// position (+ playlist index), re-init the player HTML with the new params,
  /// wait for the fresh `player` object, then reload the content with
  /// `startSeconds`.
  Future<void> _swapIframeChrome({required bool nativeControls}) async {
    final itemId = _loadedItemId;
    double pos = 0;
    int plIndex = 0;
    try {
      pos = await _yt.currentTime;
      if (_isPlaylist) plIndex = await _yt.playlistIndex;
    } catch (_) {
      // Position unknown — restart the content from 0 rather than aborting.
    }
    if (!mounted || _loadedItemId != itemId) return;
    try {
      await _yt.initWithParams(params: _paramsFor(nativeControls: nativeControls));
      final ready = await _waitForIframePlayer();
      if (!mounted || _loadedItemId != itemId || !ready) return;
      final listId = _currentListId;
      final videoId = _currentVideoId;
      if (_isPlaylist && listId != null) {
        await _runPlaylistLoad(listId, index: plIndex, startSeconds: pos);
      } else if (videoId != null) {
        await _yt.loadVideoById(videoId: videoId, startSeconds: pos);
      }
    } catch (e) {
      debugPrint('YoutubeIframePlayer: chrome swap failed: $e');
    }
  }

  /// Polls until the freshly reloaded player HTML has a live `player` object
  /// (the JS bridge's ready gate only covers the FIRST load). ~4s budget.
  Future<bool> _waitForIframePlayer() async {
    for (var i = 0; i < 40; i++) {
      try {
        final ok = await _yt.webViewController.runJavaScriptReturningResult(
          "typeof player !== 'undefined' && "
          "typeof player.loadVideoById === 'function' ? '1' : '0'",
        );
        if (ok.toString().contains('1')) return true;
      } catch (_) {
        // Page still booting — keep polling.
      }
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return false;
    }
    return false;
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
    _currentVideoId = null;
    _currentListId = null;

    if (item.type == PlaylistItemType.youtubePlaylist) {
      final listId = youtubePlaylistIdFromUrl(item.url);
      if (listId == null || listId.isEmpty) {
        widget.controller.notifyYoutubeItemError(itemId: item.id);
        return;
      }
      _currentListId = listId;
      unawaited(_loadYoutubePlaylist(listId, item.id));
      return;
    }

    final videoId =
        YoutubePlayerController.convertUrlToId(item.url) ?? item.url;
    if (videoId.isEmpty) {
      widget.controller.notifyYoutubeItemError(itemId: item.id);
      return;
    }
    _currentVideoId = videoId;
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
    final d = value.metaData.duration;
    if (d > Duration.zero) _duration = d;

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

    if (value.error != YoutubeError.none) {
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
    // Inline the surface is chromeless — every control (prev, play/pause,
    // next, fullscreen) lives OUTSIDE the player in the transport row below
    // it, each linked to the iframe through the PlaylistController channels.
    // In fullscreen the iframe swaps to YouTube's own controls (see
    // [_swapIframeChrome]).
    return YoutubePlayer(
      controller: _yt,
      aspectRatio: widget.aspectRatio,
    );
  }
}
