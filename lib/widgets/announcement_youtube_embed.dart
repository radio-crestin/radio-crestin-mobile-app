import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:url_launcher/url_launcher.dart';

import '../appAudioHandler.dart';
import '../services/announcement.dart';
import '../services/announcement_actions.dart';
import '../services/announcement_copy.dart';
import '../services/announcements_service.dart';
import '../services/autoplay_hold.dart';
import '../services/youtube_embed.dart';
import '../theme.dart';
import 'announcement_image.dart';

/// A YouTube video, Short or playlist in an announcement's page: its
/// thumbnail with a play button, which opens it in the YouTube app (spec:
/// "YouTube embeds in the announcement page", UPDATE 1 and 2).
///
/// No player runs inside the app. The radio pauses just before YouTube
/// opens, and stays paused.
class AnnouncementYoutubeEmbed extends StatelessWidget {
  const AnnouncementYoutubeEmbed({
    super.key,
    required this.embed,
    required this.announcement,
    this.details,
  });

  final YoutubeEmbed embed;
  final Announcement announcement;

  /// The backend's title and thumbnail for this link, when it has them.
  final PageEmbed? details;

  /// The tallest a Short gets: a vertical video would fill the screen.
  static const double maxShortHeight = 480;

  /// The thumbnail: the backend's, else YouTube's own for a video; null
  /// for a playlist without one (a plain tile then).
  String? get _thumbnail {
    final url = details?.thumbnail;
    if (url != null && AnnouncementActions.safeLink(url) != null) return url;
    return embed.thumbnailUrl;
  }

  String get _playLabel => switch (embed.kind) {
        YoutubeEmbedKind.video => AnnouncementCopy.playVideo,
        YoutubeEmbedKind.short => AnnouncementCopy.playShort,
        YoutubeEmbedKind.playlist => AnnouncementCopy.playPlaylist,
      };

  Future<void> _open() async {
    _pauseRadio();
    GetIt.instance<AnnouncementsService>().report(
      AnnouncementEvent.videoPlay,
      announcement,
      0,
      details: {'provider': 'youtube', 'kind': embed.kind.name},
    );
    final uri = Uri.parse(embed.url);
    // Coming back must not start the radio again (iOS autoplay on resume).
    AutoplayHold.holdNextResume();
    // The YouTube app takes https links (iOS universal links, Android
    // intents), so no app scheme or LSApplicationQueriesSchemes is needed;
    // without the app, the browser opens it.
    if (await _launch(uri, LaunchMode.externalNonBrowserApplication)) return;
    if (!await _launch(uri, LaunchMode.externalApplication)) {
      AutoplayHold.release();
    }
  }

  static Future<bool> _launch(Uri uri, LaunchMode mode) async {
    try {
      return await launchUrl(uri, mode: mode);
    } catch (_) {
      return false;
    }
  }

  /// The radio stops for the video, and stays stopped after.
  static void _pauseRadio() {
    if (!GetIt.instance.isRegistered<AppAudioHandler>()) return;
    final radio = GetIt.instance<AppAudioHandler>();
    if (radio.playbackState.value.playing) unawaited(radio.pause());
  }

  @override
  Widget build(BuildContext context) {
    final isShort = embed.kind == YoutubeEmbedKind.short;
    final colors = Theme.of(context).announcementColors;
    final thumbnail = _thumbnail;
    final tile = ColoredBox(color: colors.control);
    final facade = AspectRatio(
      aspectRatio: isShort ? 9 / 16 : 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Semantics(
          button: true,
          label: details?.title ?? _playLabel,
          hint: details?.title == null ? null : _playLabel,
          excludeSemantics: true,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const ValueKey('youtube-facade'),
              onTap: _open,
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
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: isShort
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: maxShortHeight),
                child: facade,
              ),
            )
          : facade,
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
