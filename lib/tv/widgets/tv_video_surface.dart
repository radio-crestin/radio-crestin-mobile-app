import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/video_playback_service.dart';
import '../../types/playlist_item.dart';
import '../../utils.dart';
import '../tv_platform.dart';
import '../tv_theme.dart';

/// media_kit video output for the TV / desktop shells, with a dark buffering
/// overlay. Overlay chrome (title, LIVE pill, counter, controls) is composed by
/// the caller so it can share the page's focus tree.
class TvVideoSurface extends StatelessWidget {
  const TvVideoSurface({
    super.key,
    required this.videoService,
    this.fit = BoxFit.contain,
  });

  final VideoPlaybackService videoService;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<VideoController>(
            future: videoService.ensureInitialized(),
            builder: (context, snapshot) {
              final controller = snapshot.data ?? videoService.controller;
              if (controller == null) return const _TvSpinner();
              return Video(
                controller: controller,
                controls: NoVideoControls,
                fit: fit,
                fill: Colors.black,
              );
            },
          ),
          StreamBuilder<bool>(
            stream: videoService.bufferingStream,
            initialData: videoService.isBuffering,
            builder: (context, snapshot) =>
                snapshot.data == true ? const _TvSpinner() : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _TvSpinner extends StatelessWidget {
  const _TvSpinner();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 44,
        height: 44,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation(TvColors.primary),
        ),
      ),
    );
  }
}

/// "● LIVE" pill for live TV on the dark TV/desktop surfaces.
class TvLivePill extends StatelessWidget {
  const TvLivePill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: TvColors.offline,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          const Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 13,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown on TV / desktop when a playlist reaches a YouTube item, which cannot be
/// embedded there. Displays the item, counts down ~4s and then advances via
/// [onAutoAdvance]. Desktop additionally offers "Deschide pe YouTube"; TV offers
/// a focusable skip button.
class TvYoutubeUpNextCard extends StatefulWidget {
  const TvYoutubeUpNextCard({
    super.key,
    required this.item,
    required this.onAutoAdvance,
    this.autoAdvance = const Duration(seconds: 4),
  });

  final PlaylistItem item;
  final VoidCallback onAutoAdvance;
  final Duration autoAdvance;

  @override
  State<TvYoutubeUpNextCard> createState() => _TvYoutubeUpNextCardState();
}

class _TvYoutubeUpNextCardState extends State<TvYoutubeUpNextCard> {
  Timer? _timer;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant TvYoutubeUpNextCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.id != oldWidget.item.id) {
      _advanced = false;
      _arm();
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(widget.autoAdvance, _advance);
  }

  void _advance() {
    if (_advanced) return;
    _advanced = true;
    widget.onAutoAdvance();
  }

  Future<void> _openOnYoutube() async {
    final url = widget.item.url;
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort — ignore launch failures.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.all(TvSpacing.lg),
          decoration: BoxDecoration(
            color: TvColors.surface,
            borderRadius: BorderRadius.circular(TvSpacing.radiusLg),
            border: Border.all(color: TvColors.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(TvSpacing.radiusMd),
                    child: SizedBox(
                      width: 120,
                      height: 68,
                      child: (item.thumbnailUrl != null &&
                              item.thumbnailUrl!.isNotEmpty)
                          ? Utils.displayImage(item.thumbnailUrl!,
                              cache: true, cacheWidth: 240)
                          : const ColoredBox(
                              color: TvColors.surfaceVariant,
                              child: Icon(Icons.smart_display_rounded,
                                  color: Colors.white54, size: 32),
                            ),
                    ),
                  ),
                  const SizedBox(width: TvSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                                item.type == PlaylistItemType.youtubePlaylist
                                    ? Icons.playlist_play_rounded
                                    : Icons.smart_display_rounded,
                                color: TvColors.primary,
                                size: 16),
                            const SizedBox(width: 6),
                            Text(
                                item.type == PlaylistItemType.youtubePlaylist
                                    ? 'Playlist YouTube'
                                    : 'Element YouTube',
                                style: TvTypography.caption.copyWith(
                                  color: TvColors.primary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                  letterSpacing: 0.5,
                                )),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.title.isNotEmpty ? item.title : 'Fără titlu',
                          style: TvTypography.title.copyWith(fontSize: 18),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: TvSpacing.md),
              Text(
                'Se redă următorul element…',
                style: TvTypography.body.copyWith(color: TvColors.textSecondary),
              ),
              const SizedBox(height: TvSpacing.sm),
              // Countdown bar.
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: widget.autoAdvance,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: value,
                    minHeight: 4,
                    backgroundColor: TvColors.surfaceVariant,
                    valueColor:
                        const AlwaysStoppedAnimation(TvColors.primary),
                  ),
                ),
              ),
              const SizedBox(height: TvSpacing.md),
              if (TvPlatform.isDesktop)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _DesktopAction(
                      label: 'Sari peste',
                      icon: Icons.skip_next_rounded,
                      onTap: _advance,
                    ),
                    const SizedBox(width: TvSpacing.sm),
                    _DesktopAction(
                      label: 'Deschide pe YouTube',
                      icon: Icons.open_in_new_rounded,
                      primary: true,
                      onTap: _openOnYoutube,
                    ),
                  ],
                )
              else
                _TvSkipButton(onSkip: _advance),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopAction extends StatefulWidget {
  const _DesktopAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<_DesktopAction> createState() => _DesktopActionState();
}

class _DesktopActionState extends State<_DesktopAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.primary
        ? TvColors.primary
        : (_hover ? TvColors.surfaceHigh : TvColors.surfaceVariant);
    final fg = widget.primary ? Colors.white : TvColors.textPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Text(widget.label,
                  style: TextStyle(
                      color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvSkipButton extends StatelessWidget {
  const _TvSkipButton({required this.onSkip});

  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      autofocus: true,
      onSelect: onSkip,
      builder: FocusEffects.scaleWithBorder(
        scale: 1.06,
        borderColor: TvColors.primary,
        borderWidth: 3,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: TvColors.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.skip_next_rounded, size: 20, color: Colors.white),
            SizedBox(width: 8),
            Text('Sari peste',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
