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

  int? _loadedItemId;
  bool _endedReported = false;
  Duration _duration = Duration.zero;
  bool _isFullscreen = false;

  bool get _isPlaylist =>
      widget.item.type == PlaylistItemType.youtubePlaylist;

  @override
  void initState() {
    super.initState();
    _yt = YoutubePlayerController(
      params: const YoutubePlayerParams(
        // Native controls are required for the fullscreen button (and give the
        // only reliable cross-platform way to *exit* fullscreen, e.g. iOS which
        // has no system back button). They auto-hide, keeping the surface clean.
        showControls: true,
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
    // The package renders fullscreen itself (an overlay); we only own the
    // system chrome — landscape + immersive on enter, portrait restored on exit.
    _yt.setFullScreenListener(_onFullscreenChanged);

    _loadItem(widget.item);
  }

  /// Applies the platform chrome for the player's fullscreen transitions. The
  /// player widget handles the actual fullscreen layout; here we rotate to
  /// landscape and hide the system bars when entering, and restore portrait and
  /// the system bars when exiting.
  void _onFullscreenChanged(bool fullscreen) {
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

    if (item.type == PlaylistItemType.youtubePlaylist) {
      final listId = youtubePlaylistIdFromUrl(item.url);
      if (listId == null || listId.isEmpty) {
        widget.controller.notifyYoutubeItemError();
        return;
      }
      _yt.loadPlaylist(list: [listId], listType: ListType.playlist);
      return;
    }

    final videoId =
        YoutubePlayerController.convertUrlToId(item.url) ?? item.url;
    if (videoId.isEmpty) {
      widget.controller.notifyYoutubeItemError();
      return;
    }
    _yt.loadVideoById(videoId: videoId);
  }

  void _onValue(YoutubePlayerValue value) {
    final d = value.metaData.duration;
    if (d > Duration.zero) _duration = d;

    switch (value.playerState) {
      case PlayerState.playing:
        widget.controller.notifyYoutubePlaying(true);
        break;
      case PlayerState.paused:
      case PlayerState.cued:
        widget.controller.notifyYoutubePlaying(false);
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
      widget.controller.notifyYoutubeItemError();
    }
  }

  /// End-of-media handling. For a single video, any `ended` finishes the item.
  /// For a whole playlist, `ended` fires after EVERY inner video — only the
  /// last one finishing the playlist should advance the app playlist.
  void _onEnded() {
    if (_endedReported) return;
    if (!_isPlaylist) {
      _endedReported = true;
      widget.controller.notifyYoutubeItemEnded();
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
        widget.controller.notifyYoutubeItemEnded();
      }
      // Otherwise an inner video ended — the iframe auto-advances; ignore.
    } catch (_) {
      // Couldn't determine playlist position — advance rather than get stuck.
      if (_endedReported) return;
      _endedReported = true;
      widget.controller.notifyYoutubeItemEnded();
    }
  }

  void _onPosition(YoutubeVideoState state) {
    widget.controller.notifyYoutubePosition(state.position, _duration);
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
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return YoutubePlayer(
      controller: _yt,
      aspectRatio: widget.aspectRatio,
    );
  }
}
