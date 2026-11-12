import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../appAudioHandler.dart';
import '../services/announcement.dart';
import '../services/announcement_actions.dart';
import '../services/announcement_copy.dart';
import '../services/announcements_service.dart';
import '../services/network_service.dart';
import '../services/youtube_embed.dart';
import '../theme.dart';
import 'announcement_image.dart';
import 'video_fullscreen_chrome.dart';

/// A YouTube video, Short or playlist in an announcement's page: its
/// thumbnail with a play button until tapped, then the official IFrame
/// player in its place.
///
/// Playing pauses the radio, which stays paused; only one video plays at a
/// time, and leaving the page stops it. Offline, or when the player fails,
/// the link opens in the YouTube app or the browser instead.
class AnnouncementYoutubeEmbed extends StatefulWidget {
  const AnnouncementYoutubeEmbed({
    super.key,
    required this.embed,
    required this.announcement,
  });

  final YoutubeEmbed embed;
  final Announcement announcement;

  /// The tallest a Short gets: a vertical video would fill the screen.
  static const double maxShortHeight = 480;

  @override
  State<AnnouncementYoutubeEmbed> createState() =>
      _AnnouncementYoutubeEmbedState();
}

class _AnnouncementYoutubeEmbedState extends State<AnnouncementYoutubeEmbed> {
  /// The embed playing now, so that starting one pauses the others.
  static final ValueNotifier<Object?> _playing = ValueNotifier(null);

  YoutubePlayerController? _player;
  StreamSubscription<YoutubePlayerValue>? _playerSub;
  bool _fullscreen = false;

  /// A video inside a playlist: the list loads first, then this video.
  bool _seekVideoInList = false;

  YoutubeEmbed get _embed => widget.embed;

  @override
  void initState() {
    super.initState();
    _playing.addListener(_onAnotherPlays);
  }

  @override
  void dispose() {
    _playing.removeListener(_onAnotherPlays);
    if (_playing.value == this) _playing.value = null;
    _closePlayer();
    super.dispose();
  }

  void _onAnotherPlays() {
    if (_playing.value != this) _player?.pauseVideo();
  }

  Future<void> _start() async {
    final network = GetIt.instance.isRegistered<NetworkService>()
        ? GetIt.instance<NetworkService>()
        : null;
    if (network?.isOffline.value ?? false) {
      await _openOutside();
      return;
    }
    _pauseRadio();
    GetIt.instance<AnnouncementsService>().report(
      AnnouncementEvent.videoPlay,
      widget.announcement,
      0,
      details: {'provider': 'youtube', 'kind': _embed.kind.name},
    );
    final player = YoutubePlayerController(
      params: const YoutubePlayerParams(
        // The native controls carry the fullscreen button, and the only
        // reliable way out of fullscreen on iOS.
        showControls: true,
        showFullscreenButton: true,
        enableCaption: false,
        privacyEnhancedMode: true,
        strictRelatedVideos: true,
        playsInline: true,
      ),
    );
    player.setFullScreenListener((fullscreen) {
      _fullscreen = fullscreen;
      applyVideoFullscreenChrome(fullscreen);
    });
    _playerSub = player.stream.listen(_onPlayerValue);
    setState(() => _player = player);
    _playing.value = this;
    _load(player);
  }

  void _load(YoutubePlayerController player) {
    final listId = _embed.listId;
    if (listId != null) {
      _seekVideoInList = _embed.videoId != null;
      unawaited(_loadPlaylist(player, listId));
      return;
    }
    unawaited(player.loadVideoById(
      videoId: _embed.videoId!,
      startSeconds: _embed.start?.toDouble(),
    ));
  }

  /// Loads the playlist [listId].
  ///
  /// youtube_player_iframe sends a single list as an array, which the
  /// IFrame API does not take as a playlist ID: the player stays blank. Its
  /// own call waits until the player is ready; the list then loads again
  /// with the ID as a string (checked against `[A-Za-z0-9_-]`, so it is safe
  /// inside the script).
  Future<void> _loadPlaylist(
    YoutubePlayerController player,
    String listId,
  ) async {
    try {
      await player.loadPlaylist(list: [listId], listType: ListType.playlist);
      await player.webViewController.runJavaScript(
          "player.loadPlaylist({list: '$listId', listType: 'playlist'});");
    } catch (_) {
      await _fallBackOutside();
    }
  }

  void _onPlayerValue(YoutubePlayerValue value) {
    if (value.error != YoutubeError.none) {
      unawaited(_fallBackOutside());
      return;
    }
    final state = value.playerState;
    if (state == PlayerState.playing) {
      _playing.value = this;
      _pauseRadio();
    }
    if (_seekVideoInList &&
        (state == PlayerState.playing ||
            state == PlayerState.buffering ||
            state == PlayerState.cued)) {
      _seekVideoInList = false;
      unawaited(_playVideoInList());
    }
  }

  /// Plays the linked video within its playlist, which then goes on in
  /// order from there.
  Future<void> _playVideoInList() async {
    final player = _player;
    if (player == null) return;
    try {
      final index = (await player.playlist).indexOf(_embed.videoId!);
      if (index > 0) await player.playVideoAt(index);
      final start = _embed.start;
      if (start != null) {
        await player.seekTo(seconds: start.toDouble(), allowSeekAhead: true);
      }
    } catch (_) {
      // The list plays from its start: still the playlist the link names.
    }
  }

  /// The radio stops while a video plays, and stays stopped after.
  void _pauseRadio() {
    if (!GetIt.instance.isRegistered<AppAudioHandler>()) return;
    final radio = GetIt.instance<AppAudioHandler>();
    if (radio.playbackState.value.playing) unawaited(radio.pause());
  }

  Future<void> _fallBackOutside() async {
    _closePlayer();
    if (mounted) setState(() {});
    await _openOutside();
  }

  Future<void> _openOutside() =>
      AnnouncementActions.openLink(_embed.url, LaunchMode.externalApplication);

  void _closePlayer() {
    if (_fullscreen) applyVideoFullscreenChrome(false);
    _fullscreen = false;
    _playerSub?.cancel();
    _playerSub = null;
    _player?.close();
    _player = null;
  }

  @override
  Widget build(BuildContext context) {
    final isShort = _embed.kind == YoutubeEmbedKind.short;
    final ratio = isShort ? 9 / 16 : 16 / 9;
    final player = _player;
    final box = AspectRatio(
      aspectRatio: ratio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: player == null
              ? _Facade(
                  key: const ValueKey('youtube-facade'),
                  embed: _embed,
                  onTap: _start,
                )
              : YoutubePlayer(
                  key: const ValueKey('youtube-player'),
                  controller: player,
                  aspectRatio: ratio,
                ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: isShort
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: AnnouncementYoutubeEmbed.maxShortHeight,
                ),
                child: box,
              ),
            )
          : box,
    );
  }
}

/// The thumbnail (or, for a playlist, a plain tile) with a play button.
class _Facade extends StatelessWidget {
  const _Facade({super.key, required this.embed, required this.onTap});

  final YoutubeEmbed embed;
  final VoidCallback onTap;

  String get _playLabel => switch (embed.kind) {
        YoutubeEmbedKind.video => AnnouncementCopy.playVideo,
        YoutubeEmbedKind.short => AnnouncementCopy.playShort,
        YoutubeEmbedKind.playlist => AnnouncementCopy.playPlaylist,
      };

  String get _description => switch (embed.kind) {
        YoutubeEmbedKind.video => AnnouncementCopy.videoThumbnail,
        YoutubeEmbedKind.short => AnnouncementCopy.shortThumbnail,
        YoutubeEmbedKind.playlist => AnnouncementCopy.playlistOnYoutube,
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final thumbnail = embed.thumbnailUrl;
    final tile = ColoredBox(
      color: colors.control,
      child: embed.kind == YoutubeEmbedKind.playlist
          ? _PlaylistTile(label: _description, color: colors.text)
          : null,
    );
    return Semantics(
      button: true,
      label: _playLabel,
      hint: _description,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumbnail == null)
                tile
              else
                AnnouncementImage(url: thumbnail, placeholder: tile),
              const Center(child: _PlayButton()),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_play_rounded, size: 22, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: const BoxDecoration(
        color: AppColors.videoPlayButton,
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        size: 40,
        color: AppColors.videoPlayIcon,
      ),
    );
  }
}
