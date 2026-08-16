import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:radio_crestin/theme.dart';
import 'package:video_player/video_player.dart';

import '../services/video_playback_service.dart';

/// Enters landscape immersive chrome for video fullscreen — mirrors the inline
/// YouTube fullscreen pattern so both video kinds behave identically.
Future<void> enterVideoFullscreenChrome() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
}

/// Restores portrait + edge-to-edge chrome when leaving video fullscreen.
Future<void> exitVideoFullscreenChrome() async {
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
}

/// Small "● LIVE" pill shown over live TV video.
class LivePill extends StatelessWidget {
  const LivePill({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 8,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 6 : 7,
            height: compact ? 6 : 7,
            decoration: const BoxDecoration(
              color: AppColors.offline,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: compact ? 5 : 6),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: compact ? 10 : 11,
              letterSpacing: 0.8,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Subtle "🎧 Doar audio" pill shown when video content fell back to audio-only
/// playback (the decoder couldn't render a picture). Mirrors [LivePill]'s dark
/// translucent styling so it reads as an unobtrusive status badge.
class AudioOnlyChip extends StatelessWidget {
  const AudioOnlyChip({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.headphones_rounded,
              size: compact ? 11 : 13, color: Colors.white),
          SizedBox(width: compact ? 4 : 5),
          Text(
            'Doar audio',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 10 : 11,
              letterSpacing: 0.3,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Subtle "Nu rulează în fundal" pill shown over an inline YouTube item. It is
/// a persistent (non-auto-hiding) reminder that a YouTube video can only keep
/// playing while the app stays open and the screen is on — locking the screen
/// or switching apps pauses it. Mirrors [AudioOnlyChip]'s dark translucent
/// styling so it reads as an unobtrusive status badge, not a control.
class YoutubeBackgroundChip extends StatelessWidget {
  const YoutubeBackgroundChip({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline_rounded,
              size: compact ? 11 : 13, color: Colors.white),
          SizedBox(width: compact ? 4 : 5),
          Text(
            'Nu rulează în fundal',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 10 : 11,
              letterSpacing: 0.3,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reactively renders the video_player output for the CURRENT source on a black
/// background, sizing itself from the active controller's reported dimensions.
///
/// The [VideoPlayerController] is created and owned by the engine's
/// [VideoPlaybackService]; this widget subscribes to [controllerStream] so it
/// rebinds seamlessly whenever the controller swaps (new media, or a manual
/// quality preload-then-swap), and to the controller's own value for size
/// changes. Multiple [VideoRender]s can share one controller (e.g. inline +
/// fullscreen) — video_player renders the same texture in each.
class VideoRender extends StatelessWidget {
  const VideoRender({
    super.key,
    required this.videoService,
    this.fit = BoxFit.contain,
  });

  final VideoPlaybackService videoService;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<VideoPlayerController?>(
      stream: videoService.controllerStream,
      initialData: videoService.controller,
      builder: (context, snapshot) {
        final controller = snapshot.data ?? videoService.controller;
        if (controller == null) {
          return const SizedBox.expand();
        }
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            if (!value.isInitialized ||
                value.size.width <= 0 ||
                value.size.height <= 0) {
              return const SizedBox.expand();
            }
            final video = VideoPlayer(controller);
            if (fit == BoxFit.cover) {
              return SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: value.size.width,
                    height: value.size.height,
                    child: video,
                  ),
                ),
              );
            }
            // contain (default): letterbox on the black background.
            return Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio,
                child: video,
              ),
            );
          },
        );
      },
    );
  }
}

/// The video output for the current source, with a buffering overlay and an
/// optional LIVE pill for live TV.
///
/// The [VideoPlayerController] is created and owned by the engine's
/// [VideoPlaybackService]; this widget only renders it (via [VideoRender]) and
/// composes the optional [controls] overlay on top.
class PlayerVideoSurface extends StatelessWidget {
  const PlayerVideoSurface({
    super.key,
    required this.videoService,
    this.showLivePill = false,
    this.fit = BoxFit.contain,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.controls,
  });

  final VideoPlaybackService videoService;
  final bool showLivePill;
  final BoxFit fit;
  final BorderRadius borderRadius;

  /// Optional custom controls builder (e.g. [VideoOverlayControls]). When
  /// provided, the surface hands buffering and the LIVE pill to the overlay; the
  /// built-in spinner/pill are only used for the bare (`controls == null`)
  /// surface.
  final WidgetBuilder? controls;

  @override
  Widget build(BuildContext context) {
    final hasOverlay = controls != null;
    return ClipRRect(
      borderRadius: borderRadius,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoRender(videoService: videoService, fit: fit),
            if (hasOverlay) Positioned.fill(child: Builder(builder: controls!)),
            // Bare surface only: buffering spinner + LIVE pill. With an overlay
            // present these are owned by the overlay (avoids double-rendering).
            if (!hasOverlay)
              StreamBuilder<bool>(
                stream: videoService.bufferingStream,
                initialData: videoService.isBuffering,
                builder: (context, snapshot) {
                  if (snapshot.data != true) return const SizedBox.shrink();
                  return const _SurfaceSpinner();
                },
              ),
            if (!hasOverlay && showLivePill)
              const Positioned(
                top: 8,
                left: 8,
                child: LivePill(),
              ),
          ],
        ),
      ),
    );
  }
}

class _SurfaceSpinner extends StatelessWidget {
  const _SurfaceSpinner();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 34,
        height: 34,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation(AppColors.primary),
        ),
      ),
    );
  }
}
