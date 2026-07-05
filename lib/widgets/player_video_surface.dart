import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:radio_crestin/theme.dart';

import '../services/video_playback_service.dart';

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

/// The media_kit video output for the current source, with a buffering overlay
/// and an optional LIVE pill for live TV.
///
/// The [VideoController] is created and owned by the engine's
/// [VideoPlaybackService]; this widget only reads it and mounts the `Video`
/// widget. [ensureInitialized] is idempotent, so calling it here is safe even
/// if the engine created the controller already.
class PlayerVideoSurface extends StatelessWidget {
  const PlayerVideoSurface({
    super.key,
    required this.videoService,
    this.showLivePill = false,
    this.fit = BoxFit.contain,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final VideoPlaybackService videoService;
  final bool showLivePill;
  final BoxFit fit;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<VideoController>(
              future: videoService.ensureInitialized(),
              builder: (context, snapshot) {
                final controller = snapshot.data ?? videoService.controller;
                if (controller == null) {
                  return const _SurfaceSpinner();
                }
                return Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fit: fit,
                  fill: Colors.black,
                );
              },
            ),
            // Buffering overlay — brand spinner over the video while the
            // decoder waits on data.
            StreamBuilder<bool>(
              stream: videoService.bufferingStream,
              initialData: videoService.isBuffering,
              builder: (context, snapshot) {
                if (snapshot.data != true) return const SizedBox.shrink();
                return const _SurfaceSpinner();
              },
            ),
            if (showLivePill)
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
