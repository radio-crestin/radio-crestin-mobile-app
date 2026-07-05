import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:radio_crestin/theme.dart';

import '../services/video_playback_service.dart';

/// Enters landscape immersive chrome for media_kit fullscreen — mirrors the
/// inline YouTube fullscreen pattern so both video kinds behave identically.
Future<void> enterVideoFullscreenChrome() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
}

/// Restores portrait + edge-to-edge chrome when leaving media_kit fullscreen.
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
    this.controls,
  });

  final VideoPlaybackService videoService;
  final bool showLivePill;
  final BoxFit fit;
  final BorderRadius borderRadius;

  /// Optional custom controls builder (e.g. [VideoOverlayControls]). When
  /// provided, the surface hands buffering and the LIVE pill to the overlay and
  /// wires the media_kit fullscreen chrome; the built-in spinner/pill are only
  /// used for the bare (`controls == null`) surface.
  final VideoControlsBuilder? controls;

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
            FutureBuilder<VideoController>(
              future: videoService.ensureInitialized(),
              builder: (context, snapshot) {
                final controller = snapshot.data ?? videoService.controller;
                if (controller == null) {
                  return const _SurfaceSpinner();
                }
                return Video(
                  controller: controller,
                  controls: controls ?? NoVideoControls,
                  fit: fit,
                  fill: Colors.black,
                  onEnterFullscreen: enterVideoFullscreenChrome,
                  onExitFullscreen: exitVideoFullscreenChrome,
                );
              },
            ),
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
