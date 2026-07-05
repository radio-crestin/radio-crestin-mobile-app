import 'dart:async';

import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../services/playlist_controller.dart';
import '../types/playlist_item.dart';

/// Lightweight handle the transport row uses to drive the inline YouTube
/// player without reaching into its internal controller.
///
/// The [YoutubeIframePlayer] binds its play/pause callbacks here and keeps
/// [isPlaying] up to date from the real player state, so the parent can render
/// a correct play/pause button and toggle playback.
class YoutubePlaybackHandle {
  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(true);
  VoidCallback? _play;
  VoidCallback? _pause;

  void bind({required VoidCallback play, required VoidCallback pause}) {
    _play = play;
    _pause = pause;
  }

  void play() => _play?.call();
  void pause() => _pause?.call();

  void dispose() => isPlaying.dispose();
}

/// Renders a playlist YouTube item inline via `youtube_player_iframe` and wires
/// it back to the [PlaylistController] contract:
///   - end-of-video  → [PlaylistController.notifyYoutubeItemEnded]
///   - player error  → [PlaylistController.notifyYoutubeItemError]
///   - position tick → [PlaylistController.notifyYoutubePosition]
///   - honors [PlaylistController.youtubeShouldPlay] (pauses when false, e.g.
///     the app is backgrounded — YouTube cannot play in the background).
///
/// The widget must stay mounted while the mini player is collapsed so the
/// iframe keeps playing; the full player keeps it in the tree for exactly that
/// reason.
class YoutubeIframePlayer extends StatefulWidget {
  const YoutubeIframePlayer({
    super.key,
    required this.item,
    required this.controller,
    required this.handle,
    this.aspectRatio = 16 / 9,
  });

  /// The YouTube playlist item to render.
  final PlaylistItem item;

  /// The engine's playlist controller (contract callbacks + should-play flag).
  final PlaylistController controller;

  /// Handle the transport row uses to play/pause and read playing state.
  final YoutubePlaybackHandle handle;

  final double aspectRatio;

  @override
  State<YoutubeIframePlayer> createState() => _YoutubeIframePlayerState();
}

class _YoutubeIframePlayerState extends State<YoutubeIframePlayer> {
  late final YoutubePlayerController _yt;
  StreamSubscription<YoutubePlayerValue>? _stateSub;
  StreamSubscription<YoutubeVideoState>? _positionSub;
  StreamSubscription<bool>? _shouldPlaySub;

  int? _loadedItemId;
  bool _endedReported = false;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _yt = YoutubePlayerController(
      params: const YoutubePlayerParams(
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

    widget.handle.bind(play: _yt.playVideo, pause: _yt.pauseVideo);

    _stateSub = _yt.stream.listen(_onValue);
    _positionSub = _yt.videoStateStream.listen(_onPosition);
    _shouldPlaySub =
        widget.controller.youtubeShouldPlay.stream.listen(_onShouldPlay);

    _loadItem(widget.item);
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
        widget.handle.isPlaying.value = true;
        break;
      case PlayerState.paused:
      case PlayerState.cued:
        widget.handle.isPlaying.value = false;
        break;
      case PlayerState.ended:
        if (!_endedReported) {
          _endedReported = true;
          widget.controller.notifyYoutubeItemEnded();
        }
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

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _shouldPlaySub?.cancel();
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
