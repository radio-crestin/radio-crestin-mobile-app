import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../appAudioHandler.dart';
import '../theme.dart';
import '../types/Station.dart';
import 'video_overlay_controls.dart';

/// The fullscreen face for audio-only playback: station artwork, the station
/// name and the song currently on air, under the same overlay transport the
/// video route uses.
///
/// This exists so that skipping out of a TV channel into a radio station does
/// NOT throw the user out of fullscreen. The route stays put and simply shows
/// what a radio station has to show; prev/next keep working, so the user can
/// keep skipping through the list from where they are.
///
/// Crucially it creates NO player of its own — it reads [AppAudioHandler]'s
/// streams, which is also what keeps the single-engine invariant intact.
class FullscreenAudioStage extends StatefulWidget {
  const FullscreenAudioStage({
    super.key,
    required this.audioHandler,
    required this.onExitFullscreen,
  });

  final AppAudioHandler audioHandler;

  /// Leaves the fullscreen route (wired to the overlay's exit button and its
  /// pinch-in gesture).
  final VoidCallback onExitFullscreen;

  @override
  State<FullscreenAudioStage> createState() => _FullscreenAudioStageState();
}

class _FullscreenAudioStageState extends State<FullscreenAudioStage> {
  final List<StreamSubscription<dynamic>> _subs = [];
  Station? _station;

  @override
  void initState() {
    super.initState();
    _station = widget.audioHandler.currentStation.value;
    _subs.add(widget.audioHandler.currentStation.stream.listen((s) {
      if (mounted) setState(() => _station = s);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// The song line under the station name — empty when nothing is known, so the
  /// layout never reserves space for a blank row.
  String get _nowPlaying {
    final station = _station;
    if (station == null) return '';
    final title = station.songTitle;
    if (title.isEmpty) return '';
    final artist = station.songArtist;
    return artist.isEmpty ? title : '$artist - $title';
  }

  @override
  Widget build(BuildContext context) {
    final handler = widget.audioHandler;
    return Stack(
      fit: StackFit.expand,
      children: [
        _AudioFace(station: _station, nowPlaying: _nowPlaying),
        VideoOverlayControls(
          // Radio state comes from the audio handler, never from the video
          // engine — that engine is idle (or holding a stale last frame) the
          // moment an audio-only station is playing.
          playingStream:
              handler.playbackState.stream.map((s) => s.playing).distinct(),
          initialPlaying: handler.playbackState.value.playing,
          bufferingStream: handler.playbackState.stream
              .map((s) => s.processingState == AudioProcessingState.loading ||
                  s.processingState == AudioProcessingState.buffering)
              .distinct(),
          initialBuffering: false,
          positionStream: const Stream<Duration>.empty(),
          durationStream: const Stream<Duration>.empty(),
          title: _station?.displayTitle ?? '',
          titleStream: handler.currentStation.stream
              .map((s) => s?.displayTitle ?? '')
              .distinct(),
          // A radio stream has no timeline: no scrubber, no double-tap seek.
          isLive: true,
          isFullscreen: true,
          onPlay: handler.play,
          onPause: handler.pauseFromUser,
          onPrevious: handler.skipToPrevious,
          onNext: handler.skipToNext,
          onToggleFullscreen: widget.onExitFullscreen,
        ),
      ],
    );
  }
}

/// Station artwork centred on black with the station name and the song on air,
/// crossfading whenever the station changes.
class _AudioFace extends StatelessWidget {
  const _AudioFace({required this.station, required this.nowPlaying});

  final Station? station;
  final String nowPlaying;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Landscape fullscreen is short and wide, so the artwork is sized off
        // the HEIGHT — a width-derived square would run off the screen.
        final art = (constraints.maxHeight * 0.52).clamp(120.0, 320.0);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                child: SizedBox(
                  key: ValueKey('fullscreen-art-${station?.id}'),
                  width: art,
                  height: art,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(
                        Radius.circular(AppRadius.artwork)),
                    child: station?.displayThumbnail(
                          cacheWidth:
                              (art * MediaQuery.devicePixelRatioOf(context))
                                  .ceil(),
                        ) ??
                        const ColoredBox(color: Colors.black26),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Column(
                  key: ValueKey('fullscreen-meta-${station?.id}-$nowPlaying'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      station?.displayTitle ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (nowPlaying.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        nowPlaying,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
