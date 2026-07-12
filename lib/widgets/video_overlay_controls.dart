import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:radio_crestin/theme.dart';

import '../services/video_playback_service.dart';
import 'player_video_surface.dart';

/// Diameter of the central play/pause control on the video overlay.
const double kOverlayPlayButtonSize = 56.0;

/// Diameter of the previous/next skip controls on the video overlay.
///
/// Kept deliberately small — the earlier 40+ px skip icons read as oversized
/// on the video surface (explicit user feedback). 36 px keeps them clearly
/// secondary to the 56 px play control.
const double kOverlaySkipButtonSize = 36.0;

/// Seconds a single double-tap seek jumps (YouTube-style).
const int kDoubleTapSeekSeconds = 10;

/// Formats [d] as the overlay's elapsed/total label: `m:ss`, or `h:mm:ss`
/// past an hour. Top-level and pure so the time math is trivially unit-testable.
String formatOverlayTime(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final totalSeconds = d.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final mm = minutes.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '$minutes:$ss';
}

/// Computes the target position for a double-tap seek from [position].
///
/// [forward] adds [stepSeconds]; otherwise subtracts. The result is clamped to
/// `[0, duration]` (or floored at zero when [duration] is unknown). Pure so the
/// seek arithmetic — including the clamp at both ends — is directly testable.
Duration computeDoubleTapSeek({
  required Duration position,
  required Duration? duration,
  required bool forward,
  int stepSeconds = kDoubleTapSeekSeconds,
}) {
  final delta = Duration(seconds: forward ? stepSeconds : -stepSeconds);
  var target = position + delta;
  if (target < Duration.zero) target = Duration.zero;
  if (duration != null && duration > Duration.zero && target > duration) {
    target = duration;
  }
  return target;
}

/// A selectable video quality (an HLS variant), labeled by pixel height.
@immutable
class VideoQuality {
  const VideoQuality({required this.track, required this.label});

  /// The underlying libmpv video track to select.
  final VideoTrack track;

  /// Human label, e.g. `1080p`.
  final String label;
}

/// The distinct, selectable qualities from libmpv's [tracks], highest first.
///
/// Drops the synthetic `auto`/`no` entries and any track without a known
/// height, then de-dupes by height (HLS masters often list several variants at
/// the same resolution). Pure so the label/dedupe logic is unit-testable; the
/// quality button hides itself when this yields fewer than two entries.
List<VideoQuality> distinctVideoQualities(List<VideoTrack> tracks) {
  final seenHeights = <int>{};
  final result = <VideoQuality>[];
  for (final t in tracks) {
    if (t.id == 'auto' || t.id == 'no') continue;
    final h = t.h;
    if (h == null || h <= 0) continue;
    if (!seenHeights.add(h)) continue;
    result.add(VideoQuality(track: t, label: '${h}p'));
  }
  result.sort((a, b) => (b.track.h ?? 0).compareTo(a.track.h ?? 0));
  return result;
}

/// YouTube-style controls layer drawn on top of the media_kit video surface.
///
/// Pure and stream-driven (no `media_kit` dependency) so it is fully
/// widget-testable: pass playing/buffering/position/duration streams and the
/// transport callbacks. [VideoPlayerStage] wires it to a real
/// [VideoPlaybackService] and the media_kit fullscreen route.
///
/// Behavior:
///   - Auto-hides ~3s after playback starts; any tap on the surface toggles it.
///   - Stays visible while paused or buffering (buffering shows a centered
///     spinner in place of the transport controls).
///   - VOD (`onSeek != null`, not [isLive]) shows a thin brand seek bar with
///     elapsed/total labels, a fullscreen button, and double-tap ±10s seeking.
///   - Live TV shows a `● LIVE` pill (no seek bar; a clean slot for a future
///     DVR feature) and no double-tap seek.
class VideoOverlayControls extends StatefulWidget {
  const VideoOverlayControls({
    super.key,
    required this.playingStream,
    required this.bufferingStream,
    required this.positionStream,
    required this.durationStream,
    required this.title,
    required this.onPlay,
    required this.onPause,
    this.initialPlaying = false,
    this.initialBuffering = false,
    this.initialPosition = Duration.zero,
    this.initialDuration,
    this.isLive = false,
    this.showTransport = false,
    this.isFullscreen = false,
    this.onSkipNext,
    this.onSkipPrevious,
    this.onSeek,
    this.onToggleFullscreen,
    this.videoTracksStream,
    this.initialVideoTracks = const [],
    this.selectedVideoTrackStream,
    this.initialSelectedVideoTrack,
    this.onSelectQuality,
  });

  final Stream<bool> playingStream;
  final bool initialPlaying;
  final Stream<bool> bufferingStream;
  final bool initialBuffering;
  final Stream<Duration> positionStream;
  final Duration initialPosition;
  final Stream<Duration> durationStream;
  final Duration? initialDuration;

  /// Title shown along the top of the overlay (single line, ellipsized).
  final String title;

  /// Live stream: shows the LIVE pill, hides the seek bar and disables
  /// double-tap seeking.
  final bool isLive;

  /// Playlist mode: shows the prev/next skip controls flanking play/pause.
  final bool showTransport;

  /// Whether this overlay is currently rendered inside the fullscreen route —
  /// flips the fullscreen button to its "exit" glyph.
  final bool isFullscreen;

  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback? onSkipNext;
  final VoidCallback? onSkipPrevious;

  /// Seek handler for VOD. Null (or [isLive]) means the media is not seekable —
  /// no seek bar and no double-tap seeking.
  final ValueChanged<Duration>? onSeek;

  /// Enters/exits fullscreen. Null hides the fullscreen button.
  final VoidCallback? onToggleFullscreen;

  /// Available video qualities (HLS variants). The quality button appears only
  /// for video content with more than one distinct quality; null (YouTube)
  /// hides it entirely.
  final Stream<List<VideoTrack>>? videoTracksStream;
  final List<VideoTrack> initialVideoTracks;

  /// The currently selected video track, so the picker can mark it.
  final Stream<VideoTrack>? selectedVideoTrackStream;
  final VideoTrack? initialSelectedVideoTrack;

  /// Selects a quality (pass [VideoTrack.auto] for adaptive). Null disables the
  /// quality button.
  final ValueChanged<VideoTrack>? onSelectQuality;

  @override
  State<VideoOverlayControls> createState() => _VideoOverlayControlsState();
}

class _VideoOverlayControlsState extends State<VideoOverlayControls>
    with SingleTickerProviderStateMixin {
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  List<VideoTrack> _videoTracks = const [];
  VideoTrack? _selectedTrack;

  /// User's manual toggle for the auto-hiding controls. The effective
  /// visibility ([_effectiveVisible]) additionally forces controls on while
  /// paused or buffering.
  bool _visible = true;
  Timer? _hideTimer;

  /// Optimistic play/pause shown instantly on tap until the stream confirms.
  bool? _optimisticPlaying;

  /// In-flight seek-bar drag value (ms). While set, position stream updates
  /// are ignored so the thumb tracks the finger.
  double? _dragValue;

  static const Duration _autoHideDelay = Duration(seconds: 3);

  // Double-tap seek ripple.
  late final AnimationController _rippleController;
  bool _rippleForward = false;
  int _rippleSeconds = 0;
  double _lastTapDx = 0;
  double _surfaceWidth = 0;

  bool get _seekable =>
      !widget.isLive && widget.onSeek != null;

  bool get _effectiveVisible => _visible || !_playing || _buffering;

  @override
  void initState() {
    super.initState();
    _playing = widget.initialPlaying;
    _buffering = widget.initialBuffering;
    _position = widget.initialPosition;
    _duration = widget.initialDuration;
    _videoTracks = widget.initialVideoTracks;
    _selectedTrack = widget.initialSelectedVideoTrack;

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _rippleSeconds = 0);
        }
      });

    _subs.add(widget.playingStream.listen(_onPlaying));
    _subs.add(widget.bufferingStream.listen(_onBuffering));
    _subs.add(widget.positionStream.listen((p) {
      if (mounted && _dragValue == null) setState(() => _position = p);
    }));
    _subs.add(widget.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    final tracksStream = widget.videoTracksStream;
    if (tracksStream != null) {
      _subs.add(tracksStream.listen((t) {
        if (mounted) setState(() => _videoTracks = t);
      }));
    }
    final selectedStream = widget.selectedVideoTrackStream;
    if (selectedStream != null) {
      _subs.add(selectedStream.listen((t) {
        if (mounted) setState(() => _selectedTrack = t);
      }));
    }

    if (_playing && !_buffering) _scheduleHide();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _rippleController.dispose();
    super.dispose();
  }

  void _onPlaying(bool playing) {
    if (!mounted) return;
    setState(() {
      _playing = playing;
      _optimisticPlaying = null;
    });
    if (playing && !_buffering) {
      _visible = true;
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _onBuffering(bool buffering) {
    if (!mounted) return;
    setState(() => _buffering = buffering);
    if (buffering) {
      _hideTimer?.cancel();
    } else if (_playing) {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHideDelay, () {
      if (mounted && _playing && !_buffering && _dragValue == null) {
        setState(() => _visible = false);
      }
    });
  }

  void _onSurfaceTap() {
    setState(() => _visible = !_visible);
    if (_visible && _playing && !_buffering) _scheduleHide();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _lastTapDx = details.localPosition.dx;
  }

  void _onDoubleTap() {
    if (!_seekable) return;
    final forward = _lastTapDx >= _surfaceWidth / 2;
    final target = computeDoubleTapSeek(
      position: _position,
      duration: _duration,
      forward: forward,
    );
    widget.onSeek!(target);
    setState(() {
      _position = target;
      // Accumulate when double-tapping the same side repeatedly.
      if (_rippleController.isAnimating && _rippleForward == forward) {
        _rippleSeconds += kDoubleTapSeekSeconds;
      } else {
        _rippleSeconds = kDoubleTapSeekSeconds;
      }
      _rippleForward = forward;
      _visible = true;
    });
    _rippleController.forward(from: 0);
    if (_playing) _scheduleHide();
  }

  void _togglePlay() {
    final showPlaying = _optimisticPlaying ?? _playing;
    setState(() {
      _optimisticPlaying = !showPlaying;
      _visible = true;
    });
    if (showPlaying) {
      widget.onPause();
      _hideTimer?.cancel();
    } else {
      widget.onPlay();
      _scheduleHide();
    }
  }

  void _onSkip(VoidCallback? action) {
    if (action == null) return;
    action();
    setState(() {
      _optimisticPlaying = true;
      _visible = true;
    });
    _scheduleHide();
  }

  Future<void> _openQualityPicker(List<VideoQuality> qualities) async {
    _hideTimer?.cancel();
    setState(() => _visible = true);
    final selectedId = _selectedTrack?.id ?? 'auto';
    final chosen = await showModalBottomSheet<VideoTrack>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      builder: (ctx) => _QualitySheet(
        qualities: qualities,
        selectedId: selectedId,
      ),
    );
    if (chosen != null) widget.onSelectQuality?.call(chosen);
    if (mounted && _playing && !_buffering) _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final showPlaying = _optimisticPlaying ?? _playing;
    // Quality button only for video content (onSelectQuality != null) exposing
    // more than one distinct quality.
    final qualities = widget.onSelectQuality != null
        ? distinctVideoQualities(_videoTracks)
        : const <VideoQuality>[];
    final showQuality = qualities.length > 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        _surfaceWidth = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onSurfaceTap,
          onDoubleTapDown: _seekable ? _onDoubleTapDown : null,
          onDoubleTap: _seekable ? _onDoubleTap : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Top + bottom scrim — guarantees WCAG contrast for the white
              // title and controls over any video frame.
              IgnorePointer(
                child: AnimatedOpacity(
                  key: const ValueKey('video-overlay-scrim'),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  opacity: _effectiveVisible ? 1.0 : 0.0,
                  child: const _Scrim(),
                ),
              ),
              // Double-tap seek ripple (VOD only).
              if (_seekable)
                _SeekRipple(
                  controller: _rippleController,
                  onLeft: !_rippleForward,
                  seconds: _rippleSeconds,
                ),
              // Controls layer. While buffering the play/pause button itself
              // shows the spinner (a single spinner, sized-stable), so the
              // controls stay visible instead of being replaced.
              AnimatedOpacity(
                key: const ValueKey('video-overlay-controls'),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                opacity: _effectiveVisible ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !_effectiveVisible,
                  child: _ControlsLayer(
                    title: widget.title,
                    isLive: widget.isLive,
                    seekable: _seekable,
                    showTransport: widget.showTransport,
                    isFullscreen: widget.isFullscreen,
                    showPlaying: showPlaying,
                    buffering: _buffering,
                    position: _position,
                    duration: _duration,
                    dragValue: _dragValue,
                    showQuality: showQuality,
                    onOpenQuality:
                        showQuality ? () => _openQualityPicker(qualities) : null,
                    onTogglePlay: _togglePlay,
                    onSkipNext: widget.showTransport
                        ? () => _onSkip(widget.onSkipNext)
                        : null,
                    onSkipPrevious: widget.showTransport
                        ? () => _onSkip(widget.onSkipPrevious)
                        : null,
                    onSeekChanged: (v) {
                      _hideTimer?.cancel();
                      setState(() => _dragValue = v);
                    },
                    onSeekEnd: (v) {
                      widget.onSeek?.call(Duration(milliseconds: v.round()));
                      setState(() {
                        _position = Duration(milliseconds: v.round());
                        _dragValue = null;
                      });
                      if (_playing) _scheduleHide();
                    },
                    onToggleFullscreen: widget.onToggleFullscreen,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Top + bottom darkening gradient behind the overlay text and controls.
class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x8C000000), // ~55% black at the top (title)
            Color(0x1A000000),
            Color(0x1A000000),
            Color(0x99000000), // ~60% black at the bottom (controls)
          ],
          stops: [0.0, 0.28, 0.6, 1.0],
        ),
      ),
    );
  }
}

/// Title (top) + play/pause & skips (center) + seek bar / LIVE pill (bottom).
class _ControlsLayer extends StatelessWidget {
  const _ControlsLayer({
    required this.title,
    required this.isLive,
    required this.seekable,
    required this.showTransport,
    required this.isFullscreen,
    required this.showPlaying,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.dragValue,
    required this.showQuality,
    required this.onOpenQuality,
    required this.onTogglePlay,
    required this.onSkipNext,
    required this.onSkipPrevious,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onToggleFullscreen,
  });

  final String title;
  final bool isLive;
  final bool seekable;
  final bool showTransport;
  final bool isFullscreen;
  final bool showPlaying;
  final bool buffering;
  final Duration position;
  final Duration? duration;
  final double? dragValue;
  final bool showQuality;
  final VoidCallback? onOpenQuality;
  final VoidCallback onTogglePlay;
  final VoidCallback? onSkipNext;
  final VoidCallback? onSkipPrevious;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top: title.
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Center: quality | prev | play/pause | next | fullscreen.
        Expanded(
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showQuality)
                  _QualityButton(onTap: onOpenQuality),
                if (showQuality) const SizedBox(width: 22),
                if (showTransport)
                  _SkipButton(
                    icon: Icons.skip_previous_rounded,
                    onTap: onSkipPrevious,
                  ),
                if (showTransport) const SizedBox(width: 26),
                _PlayPauseButton(
                  showPlaying: showPlaying,
                  buffering: buffering,
                  onTap: onTogglePlay,
                ),
                if (showTransport) const SizedBox(width: 26),
                if (showTransport)
                  _SkipButton(
                    icon: Icons.skip_next_rounded,
                    onTap: onSkipNext,
                  ),
                if (onToggleFullscreen != null) const SizedBox(width: 22),
                if (onToggleFullscreen != null)
                  _FullscreenButton(
                    isFullscreen: isFullscreen,
                    onTap: onToggleFullscreen!,
                  ),
              ],
            ),
          ),
        ),
        // Bottom: VOD seek bar or LIVE pill (fullscreen now lives in the row
        // above, so the bottom bar stays minimal).
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: seekable
              ? _VodBottomBar(
                  position: position,
                  duration: duration,
                  dragValue: dragValue,
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                )
              : _LiveBottomBar(showLivePill: isLive),
        ),
      ],
    );
  }
}

/// Central play/pause with a subtle translucent disc and a 150ms icon swap.
///
/// While [buffering] the disc shows a brand spinner in place of the glyph — the
/// single buffering indicator for the whole overlay (the button keeps its size
/// so the row never jumps). It stays tappable so the user can still pause.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.showPlaying,
    required this.buffering,
    required this.onTap,
  });

  final bool showPlaying;
  final bool buffering;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.32),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: kOverlayPlayButtonSize,
          height: kOverlayPlayButtonSize,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: buffering
                ? const SizedBox(
                    key: ValueKey('buffering'),
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(AppColors.primary),
                    ),
                  )
                : Icon(
                    showPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    key: ValueKey(showPlaying),
                    color: Colors.white,
                    size: kOverlayPlayButtonSize * 0.62,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Small prev/next skip control (playlist mode only).
class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            color: Colors.white,
            size: kOverlaySkipButtonSize,
          ),
        ),
      ),
    );
  }
}

/// Thin brand seek bar with elapsed/total labels.
class _VodBottomBar extends StatelessWidget {
  const _VodBottomBar({
    required this.position,
    required this.duration,
    required this.dragValue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Duration position;
  final Duration? duration;
  final double? dragValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration?.inMilliseconds ?? 0;
    final hasDuration = totalMs > 0;
    final positionMs = position.inMilliseconds
        .clamp(0, hasDuration ? totalMs : position.inMilliseconds)
        .toDouble();
    final sliderValue = dragValue ?? positionMs;
    final maxValue = hasDuration ? totalMs.toDouble() : 1.0;
    final elapsed = formatOverlayTime(
        Duration(milliseconds: (dragValue ?? positionMs).round()));
    final total = hasDuration ? formatOverlayTime(duration!) : '--:--';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Text('$elapsed / $total', style: _labelStyle),
              const Spacer(),
            ],
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.0,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.32),
            thumbColor: AppColors.primary,
            overlayColor: AppColors.primary.withValues(alpha: 0.25),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: sliderValue.clamp(0.0, maxValue),
            max: maxValue,
            onChanged: hasDuration ? onChanged : null,
            onChangeEnd: hasDuration ? onChangeEnd : null,
          ),
        ),
      ],
    );
  }

  static const TextStyle _labelStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// LIVE pill (bottom-left). No seek bar — a clean slot for a future DVR
/// feature. Fullscreen now lives in the center control row.
class _LiveBottomBar extends StatelessWidget {
  const _LiveBottomBar({required this.showLivePill});

  final bool showLivePill;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (showLivePill) const LivePill(),
          const Spacer(),
        ],
      ),
    );
  }
}

/// Small quality (gear) control shown left of the transport for multi-quality
/// video. Opens the [_QualitySheet].
class _QualityButton extends StatelessWidget {
  const _QualityButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(
            Icons.high_quality_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}

/// Material 3 bottom sheet listing "Auto" + each distinct video quality.
/// Returns the chosen [VideoTrack] (or [VideoTrack.auto] for Auto).
class _QualitySheet extends StatelessWidget {
  const _QualitySheet({required this.qualities, required this.selectedId});

  final List<VideoQuality> qualities;
  final String selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Calitate video',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
          _QualityTile(
            label: 'Auto',
            selected: selectedId == 'auto',
            onTap: () => Navigator.of(context).pop(VideoTrack.auto()),
          ),
          for (final q in qualities)
            _QualityTile(
              label: q.label,
              selected: q.track.id == selectedId,
              onTap: () => Navigator.of(context).pop(q.track),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _QualityTile extends StatelessWidget {
  const _QualityTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: selected
          ? const Icon(Icons.check_rounded, color: AppColors.primary)
          : null,
      selected: selected,
      onTap: onTap,
    );
  }
}

/// Enter/exit fullscreen glyph.
class _FullscreenButton extends StatelessWidget {
  const _FullscreenButton({required this.isFullscreen, required this.onTap});

  final bool isFullscreen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            isFullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}

/// YouTube-style double-tap seek ripple: a translucent half-disc with a
/// fast-forward/rewind glyph and the accumulated seconds, fading over ~400ms.
class _SeekRipple extends StatelessWidget {
  const _SeekRipple({
    required this.controller,
    required this.onLeft,
    required this.seconds,
  });

  final AnimationController controller;
  final bool onLeft;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final v = controller.value;
          if (v == 0 || seconds == 0) return const SizedBox.shrink();
          // 0 → 1 → 0 fade over the run.
          final opacity = math.sin(v * math.pi).clamp(0.0, 1.0);
          return Align(
            alignment: onLeft ? Alignment.centerLeft : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Opacity(
                opacity: opacity,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.horizontal(
                      left: onLeft
                          ? Radius.zero
                          : const Radius.circular(1000),
                      right: onLeft
                          ? const Radius.circular(1000)
                          : Radius.zero,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        onLeft
                            ? Icons.fast_rewind_rounded
                            : Icons.fast_forward_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$seconds sec',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Composes [PlayerVideoSurface] with [VideoOverlayControls] and wires the
/// media_kit fullscreen route.
///
/// This is the widget the full player embeds for media_kit video (TV channels
/// and video playlist items). It reads the reactive streams straight off
/// [videoService] and drives the fullscreen button through the library's
/// context-based `toggleFullscreen` — which re-runs this same controls builder
/// inside the fullscreen route, so the overlay is identical there.
class VideoPlayerStage extends StatelessWidget {
  const VideoPlayerStage({
    super.key,
    required this.videoService,
    required this.title,
    required this.onPlay,
    required this.onPause,
    this.isLive = false,
    this.showTransport = false,
    this.onSkipNext,
    this.onSkipPrevious,
    this.onSeek,
    this.allowFullscreen = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  final VideoPlaybackService videoService;
  final String title;
  final bool isLive;
  final bool showTransport;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback? onSkipNext;
  final VoidCallback? onSkipPrevious;
  final ValueChanged<Duration>? onSeek;
  final bool allowFullscreen;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return PlayerVideoSurface(
      videoService: videoService,
      fit: BoxFit.contain,
      borderRadius: borderRadius,
      controls: (state) => Builder(
        builder: (ctx) => VideoOverlayControls(
          playingStream: videoService.playingStream,
          initialPlaying: videoService.isPlaying,
          bufferingStream: videoService.bufferingStream,
          initialBuffering: videoService.isBuffering,
          positionStream: videoService.positionStream,
          initialPosition: videoService.position,
          durationStream: videoService.durationStream,
          initialDuration: videoService.duration,
          title: title,
          isLive: isLive,
          showTransport: showTransport,
          isFullscreen: isFullscreen(ctx),
          onPlay: onPlay,
          onPause: onPause,
          onSkipNext: onSkipNext,
          onSkipPrevious: onSkipPrevious,
          onSeek: onSeek,
          onToggleFullscreen:
              allowFullscreen ? () => toggleFullscreen(ctx) : null,
          videoTracksStream: videoService.videoTracksStream,
          initialVideoTracks: videoService.videoTracks,
          selectedVideoTrackStream: videoService.selectedVideoTrackStream,
          initialSelectedVideoTrack: videoService.selectedVideoTrack,
          onSelectQuality: videoService.setVideoQuality,
        ),
      ),
    );
  }
}
