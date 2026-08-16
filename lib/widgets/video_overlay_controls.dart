import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:radio_crestin/theme.dart';

import '../services/video_playback_service.dart';
import '../services/video_quality.dart';
import 'player_video_surface.dart';

export '../services/video_quality.dart' show VideoQuality;

/// Diameter of the central play/pause control on the video overlay.
const double kOverlayPlayButtonSize = 56.0;

/// Seconds a single double-tap seek jumps (YouTube-style).
const int kDoubleTapSeekSeconds = 10;

/// Minimum reported live-stream duration before the overlay treats a live
/// stream as DVR-scrubbable. A live HLS window shorter than this (or a window
/// libmpv hasn't probed yet, reported as ~0) offers no useful seek range, so
/// the overlay keeps the plain LIVE bar instead of a near-empty scrubber.
const Duration kMinLiveDvrWindow = Duration(seconds: 30);

/// Inactivity delay before the INLINE video surface fades its controls out
/// (the seek bar / scrubber plus the corner fullscreen and quality buttons).
///
/// Much longer than the fullscreen delay on purpose: inline, the video shares
/// the screen with the title, transport and track list, so the controls are not
/// in the way — they only need to step aside once the user has clearly settled
/// into watching.
const Duration kInlineControlsAutoHideDelay = Duration(seconds: 20);

/// Inactivity delay for the FULLSCREEN transport overlay (YouTube-like).
const Duration kFullscreenControlsAutoHideDelay = Duration(seconds: 3);

/// The inactivity delay after which the auto-hiding controls fade out. Pure so
/// the inline-vs-fullscreen timing contract is unit-testable without timers.
Duration videoControlsAutoHideDelay({required bool isFullscreen}) =>
    isFullscreen
        ? kFullscreenControlsAutoHideDelay
        : kInlineControlsAutoHideDelay;

/// Whether the auto-hiding controls should currently be shown (and be
/// hit-testable).
///
/// [userVisible] is the inactivity timer's own state — false once the timer
/// elapsed, true again after any interaction. Playback state overrides it:
/// while PAUSED or buffering the controls always stay up, so a paused video
/// never strands the user without a scrubber. Pure so the whole show/hide
/// decision is testable without pumping timers.
bool shouldShowVideoControls({
  required bool userVisible,
  required bool playing,
  required bool buffering,
}) =>
    userVisible || !playing || buffering;

/// Fade transition for the overlay's [AnimatedSwitcher]s that never collides
/// with itself.
///
/// [AnimatedSwitcher.defaultTransitionBuilder] gives its `FadeTransition` the
/// CHILD's key, and `KeyedSubtree.wrap` then reuses that key for the switcher's
/// internal `Stack` child. So a child key that comes back while the previous
/// instance is still fading out lands in the same `Stack` twice and the
/// framework throws "Duplicate keys found". Buffering flips on/off far faster
/// than the 150ms fade (every rebuffer of a live stream), which is exactly how
/// the inline spinner crashed the TV overlay. A KEYLESS transition makes
/// `KeyedSubtree.wrap` fall back to the switcher's monotonic child counter, so
/// every entry is unique while the children keep their own keys (which is what
/// drives the switch in the first place).
Widget _uniqueFade(Widget child, Animation<double> animation) =>
    FadeTransition(opacity: animation, child: child);

/// Formats the distance [behind] the live edge as a `-m:ss` chip for the live
/// DVR bar, or `● LIVE`-adjacent when effectively at the edge. Pure so the
/// threshold + formatting are unit-testable.
String formatBehindLive(Duration behind) {
  if (behind < const Duration(seconds: 5)) return 'LIVE';
  return '-${formatOverlayTime(behind)}';
}

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

/// Shows the quality picker ("Auto" + [qualities], highest first) and returns
/// the chosen [VideoQuality] ([VideoQuality.auto] for Auto), or null when
/// dismissed. Shared by the fullscreen overlay and the below-title transport.
///
/// Rendered as a compact CENTERED dialog rather than a bottom sheet: a bottom
/// sheet sizes to the bottom edge, which in the fullscreen landscape-immersive
/// route lands partly off-screen. A centered, content-sized dialog is always
/// fully on-screen in both inline portrait and fullscreen landscape, and reads
/// as a native picker in either.
Future<VideoQuality?> showVideoQualitySheet(
  BuildContext context, {
  required List<VideoQuality> qualities,
  required String selectedId,
}) {
  return showDialog<VideoQuality>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) => _QualityDialog(
      qualities: qualities,
      selectedId: selectedId,
    ),
  );
}

/// YouTube-style controls layer drawn on top of the media_kit video surface.
///
/// Pure and stream-driven (no `media_kit` dependency) so it is fully
/// widget-testable: pass playing/buffering/position/duration streams and the
/// transport callbacks. [VideoPlayerStage] wires it to a real
/// [VideoPlaybackService] and the media_kit fullscreen route.
///
/// Behavior:
///   - Auto-hides after a period of inactivity WHILE PLAYING: ~3s fullscreen,
///     20s inline ([videoControlsAutoHideDelay]). Any tap on the surface toggles
///     the controls back on and restarts the timer; scrubbing, the quality
///     picker and the fullscreen button restart it too.
///   - Stays visible while paused or buffering (buffering shows a centered
///     spinner: inline a standalone one, fullscreen inside the play button).
///   - Pinch-out on the surface enters fullscreen; pinch-in exits it. Tracked
///     on raw pointers (not a `ScaleGestureRecognizer`) so it never competes
///     with the tap/double-tap recognizers or the seek-bar drag.
///   - VOD (`onSeek != null`, not [isLive]) shows a thin brand seek bar with
///     elapsed/total labels, a fullscreen button, and double-tap ±10s seeking.
///   - Live TV with a DVR window (`isLive`, `onSeek != null`, and a reported
///     duration ≥ [kMinLiveDvrWindow]) shows a `● LIVE` pill, a `-m:ss`
///     behind-live label and a seek bar spanning the window (drag to the far
///     right = the live edge). Double-tap seeking stays off for live.
///   - Live TV without a known window shows just the `● LIVE` pill (no seek
///     bar) and no double-tap seek.
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
    this.fallbackDuration,
    this.isLive = false,
    this.isFullscreen = false,
    this.onSeek,
    this.onToggleFullscreen,
    this.qualitiesStream,
    this.initialQualities = const [],
    this.selectedQualityStream,
    this.initialSelectedQuality,
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

  /// Known total length (e.g. the playlist item's `duration_seconds`) used to
  /// enable the seek bar and clamp double-tap seeks before the player has
  /// reported its own duration. Ignored once a positive stream duration arrives.
  final Duration? fallbackDuration;

  /// Title shown along the top of the overlay (single line, ellipsized).
  final String title;

  /// Live stream: shows the LIVE pill, hides the seek bar and disables
  /// double-tap seeking.
  final bool isLive;

  /// Whether this overlay is currently rendered inside the fullscreen route —
  /// flips the fullscreen button to its "exit" glyph.
  final bool isFullscreen;

  final VoidCallback onPlay;
  final VoidCallback onPause;

  /// Seek handler for VOD. Null (or [isLive]) means the media is not seekable —
  /// no seek bar and no double-tap seeking.
  final ValueChanged<Duration>? onSeek;

  /// Enters/exits fullscreen. Null hides the fullscreen button.
  final VoidCallback? onToggleFullscreen;

  /// Available video qualities (HLS variants, already de-duped, no `Auto`). The
  /// quality button appears only for video content with more than one distinct
  /// quality; null (YouTube) hides it entirely.
  final Stream<List<VideoQuality>>? qualitiesStream;
  final List<VideoQuality> initialQualities;

  /// The currently selected quality, so the picker can mark it.
  final Stream<VideoQuality>? selectedQualityStream;
  final VideoQuality? initialSelectedQuality;

  /// Selects a quality (pass [VideoQuality.auto] for adaptive). Null disables
  /// the quality button.
  final ValueChanged<VideoQuality>? onSelectQuality;

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
  List<VideoQuality> _qualities = const [];
  VideoQuality? _selectedQuality;

  /// The inactivity timer's state (also flipped by the user's surface taps).
  /// The effective visibility ([_effectiveVisible]) additionally forces the
  /// controls on while paused or buffering.
  bool _visible = true;
  Timer? _hideTimer;

  /// Optimistic play/pause shown instantly on tap until the stream confirms.
  bool? _optimisticPlaying;

  /// In-flight seek-bar drag value (ms). While set, position stream updates
  /// are ignored so the thumb tracks the finger.
  double? _dragValue;

  /// This overlay's inactivity delay — 3s fullscreen, 20s inline.
  Duration get _autoHideDelay =>
      videoControlsAutoHideDelay(isFullscreen: widget.isFullscreen);

  // Double-tap seek ripple.
  late final AnimationController _rippleController;
  bool _rippleForward = false;
  int _rippleSeconds = 0;
  double _lastTapDx = 0;
  double _surfaceWidth = 0;

  // Pinch-to-fullscreen tracking. Raw pointer positions by pointer id — kept
  // out of the gesture arena so pinching never steals the tap/double-tap or
  // seek-bar gestures.
  final Map<int, Offset> _pinchPositions = {};
  double? _pinchBaseDistance;

  /// Set once a pinch crosses a threshold; blocks re-triggering until the
  /// fingers lift, so a single pinch toggles fullscreen exactly once.
  bool _pinchHandled = false;

  /// Pinch-out ratio (current/base finger distance) that enters fullscreen.
  static const double _pinchOutThreshold = 1.3;

  /// Pinch-in ratio that exits fullscreen.
  static const double _pinchInThreshold = 0.75;

  bool get _seekable => !widget.isLive && widget.onSeek != null;

  /// A live stream that exposes a scrubbable DVR window: seekable, but with the
  /// live-edge framing (LIVE pill + behind-live label) instead of elapsed/total.
  /// Gated on a reported window ≥ [kMinLiveDvrWindow] so a not-yet-probed live
  /// stream falls back to the plain LIVE bar rather than a near-empty scrubber.
  bool get _liveDvrSeekable {
    if (!widget.isLive || widget.onSeek == null) return false;
    final d = _effectiveDuration;
    return d != null && d >= kMinLiveDvrWindow;
  }

  /// The stream-reported duration when known & positive, else the caller's
  /// [VideoOverlayControls.fallbackDuration] so the seek bar works immediately.
  Duration? get _effectiveDuration {
    final d = _duration;
    if (d != null && d > Duration.zero) return d;
    return widget.fallbackDuration;
  }

  bool get _effectiveVisible => shouldShowVideoControls(
        userVisible: _visible,
        playing: _playing,
        buffering: _buffering,
      );

  @override
  void initState() {
    super.initState();
    _playing = widget.initialPlaying;
    _buffering = widget.initialBuffering;
    _position = widget.initialPosition;
    _duration = widget.initialDuration;
    _qualities = widget.initialQualities;
    _selectedQuality = widget.initialSelectedQuality;

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
    final qualitiesStream = widget.qualitiesStream;
    if (qualitiesStream != null) {
      _subs.add(qualitiesStream.listen((q) {
        if (mounted) setState(() => _qualities = q);
      }));
    }
    final selectedStream = widget.selectedQualityStream;
    if (selectedStream != null) {
      _subs.add(selectedStream.listen((q) {
        if (mounted) setState(() => _selectedQuality = q);
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

  /// A tap on the video surface: hidden controls come back (and the inactivity
  /// countdown restarts), visible controls step aside (YouTube-style toggle).
  void _onSurfaceTap() {
    setState(() => _visible = !_visible);
    if (_visible && _playing && !_buffering) _scheduleHide();
  }

  /// Keeps the controls up and restarts the inactivity countdown after a
  /// deliberate interaction (fullscreen toggle, quality pick, scrub).
  void _noteInteraction() {
    if (!_visible) setState(() => _visible = true);
    if (_playing && !_buffering) _scheduleHide();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _lastTapDx = details.localPosition.dx;
  }

  void _onDoubleTap() {
    if (!_seekable) return;
    final forward = _lastTapDx >= _surfaceWidth / 2;
    final target = computeDoubleTapSeek(
      position: _position,
      duration: _effectiveDuration,
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

  Future<void> _openQualityPicker(List<VideoQuality> qualities) async {
    _hideTimer?.cancel();
    setState(() => _visible = true);
    final chosen = await showVideoQualitySheet(
      context,
      qualities: qualities,
      selectedId: _selectedQuality?.id ?? 'auto',
    );
    if (chosen != null) widget.onSelectQuality?.call(chosen);
    if (mounted && _playing && !_buffering) _scheduleHide();
  }

  double get _pinchDistance {
    final points = _pinchPositions.values.toList();
    return (points[0] - points[1]).distance;
  }

  void _onPinchPointerDown(PointerDownEvent event) {
    _pinchPositions[event.pointer] = event.position;
    if (_pinchPositions.length == 2) {
      _pinchBaseDistance = _pinchDistance;
      _pinchHandled = false;
    }
  }

  void _onPinchPointerMove(PointerMoveEvent event) {
    if (!_pinchPositions.containsKey(event.pointer)) return;
    _pinchPositions[event.pointer] = event.position;
    if (_pinchPositions.length != 2 || _pinchHandled) return;
    final base = _pinchBaseDistance;
    if (base == null || base <= 0) return;
    final scale = _pinchDistance / base;
    if (scale >= _pinchOutThreshold) {
      // Pinch-out: enter fullscreen. Already fullscreen → nothing to do.
      _pinchHandled = true;
      if (!widget.isFullscreen) widget.onToggleFullscreen?.call();
    } else if (scale <= _pinchInThreshold) {
      // Pinch-in: exit fullscreen. Inline stays as it is.
      _pinchHandled = true;
      if (widget.isFullscreen) widget.onToggleFullscreen?.call();
    }
  }

  void _onPinchPointerEnd(PointerEvent event) {
    _pinchPositions.remove(event.pointer);
    if (_pinchPositions.length < 2) _pinchBaseDistance = null;
  }

  @override
  Widget build(BuildContext context) {
    final showPlaying = _optimisticPlaying ?? _playing;
    // Quality button only for video content (onSelectQuality != null) exposing
    // more than one distinct quality. The service already de-dupes/sorts and
    // only publishes when there is a real choice (no separate audio groups).
    final qualities = widget.onSelectQuality != null
        ? _qualities
        : const <VideoQuality>[];
    final showQuality = qualities.length > 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        _surfaceWidth = constraints.maxWidth;
        return Listener(
          // Raw-pointer pinch tracking (see _onPinchPointerMove). A Listener
          // observes events without entering the gesture arena, so taps,
          // double-taps and the seek-bar drag keep working unchanged.
          onPointerDown: _onPinchPointerDown,
          onPointerMove: _onPinchPointerMove,
          onPointerUp: _onPinchPointerEnd,
          onPointerCancel: _onPinchPointerEnd,
          child: GestureDetector(
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
                      liveDvrSeekable: _liveDvrSeekable,
                      isFullscreen: widget.isFullscreen,
                      showPlaying: showPlaying,
                      buffering: _buffering,
                      position: _position,
                      duration: _effectiveDuration,
                      dragValue: _dragValue,
                      showQuality: showQuality,
                      onOpenQuality: showQuality
                          ? () => _openQualityPicker(qualities)
                          : null,
                      onTogglePlay: _togglePlay,
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
                      onToggleFullscreen: widget.onToggleFullscreen == null
                          ? null
                          : () {
                              _noteInteraction();
                              widget.onToggleFullscreen!();
                            },
                    ),
                  ),
                ),
              ],
            ),
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

/// Top row (title in fullscreen + quality) + centered play/pause (fullscreen)
/// or buffering spinner (inline) + bottom seek bar / LIVE pill carrying the
/// bottom-right fullscreen toggle.
///
/// Corner layout mirrors YouTube's convention: the quality selector sits in the
/// TOP-RIGHT corner (fullscreen AND inline), and the enter/exit-fullscreen
/// button in the BOTTOM-RIGHT corner (below the seek line). The center holds
/// ONLY the play/pause control (explicit user feedback: in fullscreen the
/// middle previously showed prev/play/next/fullscreen). Skipping stays on the
/// playlist section's below-video transport.
class _ControlsLayer extends StatelessWidget {
  const _ControlsLayer({
    required this.title,
    required this.isLive,
    required this.seekable,
    required this.liveDvrSeekable,
    required this.isFullscreen,
    required this.showPlaying,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.dragValue,
    required this.showQuality,
    required this.onOpenQuality,
    required this.onTogglePlay,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onToggleFullscreen,
  });

  final String title;
  final bool isLive;
  final bool seekable;
  final bool liveDvrSeekable;
  final bool isFullscreen;
  final bool showPlaying;
  final bool buffering;
  final Duration position;
  final Duration? duration;
  final double? dragValue;
  final bool showQuality;
  final VoidCallback? onOpenQuality;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    // Quality sits in the TOP-RIGHT corner, both fullscreen and inline (the
    // playlist section's transport row keeps its own picker too).
    final topShowQuality = showQuality && onOpenQuality != null;
    final content = Column(
      children: [
        // Top row: fullscreen carries the title (left) + quality (top-right
        // corner); inline shows only the quality button in the same corner —
        // the playlist section already shows the item title below the video.
        if (isFullscreen || topShowQuality)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 0),
            child: Row(
              children: [
                Expanded(
                  child: isFullscreen
                      ? Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (topShowQuality) _QualityButton(onTap: onOpenQuality),
              ],
            ),
          ),
        // Center: play/pause in fullscreen. Inline, the video surface stays
        // clean — its transport lives below the video — except a standard
        // buffering spinner so loading is visible on the surface itself.
        Expanded(
          child: Center(
            child: isFullscreen
                ? _PlayPauseButton(
                    showPlaying: showPlaying,
                    buffering: buffering,
                    onTap: onTogglePlay,
                  )
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    transitionBuilder: _uniqueFade,
                    child: buffering
                        ? const _BufferingSpinner(
                            key: ValueKey('inline-buffering'))
                        : const SizedBox.shrink(key: ValueKey('inline-idle')),
                  ),
          ),
        ),
        // Bottom: VOD seek bar, live DVR seek bar, or plain LIVE pill — each
        // carrying the enter/exit-fullscreen toggle in the bottom-right corner
        // (below the seek line, YouTube-style). Fullscreen gets extra breathing
        // room around the bar; inline stays tighter on the small surface.
        Padding(
          padding: isFullscreen
              ? const EdgeInsets.fromLTRB(10, 0, 10, 14)
              : const EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: seekable
              ? _VodBottomBar(
                  position: position,
                  duration: duration,
                  dragValue: dragValue,
                  onChanged: onSeekChanged,
                  onChangeEnd: onSeekEnd,
                  isFullscreen: isFullscreen,
                  onToggleFullscreen: onToggleFullscreen,
                )
              : liveDvrSeekable
                  ? _LiveDvrBottomBar(
                      position: position,
                      duration: duration!,
                      dragValue: dragValue,
                      onChanged: onSeekChanged,
                      onChangeEnd: onSeekEnd,
                      isFullscreen: isFullscreen,
                      onToggleFullscreen: onToggleFullscreen,
                    )
                  : _LiveBottomBar(
                      showLivePill: isLive,
                      isFullscreen: isFullscreen,
                      onToggleFullscreen: onToggleFullscreen,
                    ),
        ),
      ],
    );
    // In fullscreen, keep the corner controls (title, quality, fullscreen-exit)
    // clear of the landscape display cutout (notch) and rounded screen edges.
    return isFullscreen
        ? SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 8),
            child: content,
          )
        : content;
  }
}

/// Standard buffering spinner (CLAUDE.md: `strokeWidth: 2.5`, brand color)
/// shown centered on the inline surface while the video buffers. Fullscreen
/// carries the same spinner inside [_PlayPauseButton] instead.
class _BufferingSpinner extends StatelessWidget {
  const _BufferingSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 34,
      height: 34,
      child: CircularProgressIndicator(
        strokeWidth: 2.5,
        valueColor: AlwaysStoppedAnimation(AppColors.primary),
      ),
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
            transitionBuilder: _uniqueFade,
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

/// Thin brand seek bar with elapsed/total labels and the enter/exit-fullscreen
/// toggle pinned to the bottom-right corner, below the seek line (YouTube-style).
class _VodBottomBar extends StatelessWidget {
  const _VodBottomBar({
    required this.position,
    required this.duration,
    required this.dragValue,
    required this.onChanged,
    required this.onChangeEnd,
    required this.isFullscreen,
    required this.onToggleFullscreen,
  });

  final Duration position;
  final Duration? duration;
  final double? dragValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool isFullscreen;
  final VoidCallback? onToggleFullscreen;

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
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: [
              Text('$elapsed / $total', style: _labelStyle),
              const Spacer(),
              if (onToggleFullscreen != null)
                _FullscreenButton(
                  isFullscreen: isFullscreen,
                  onTap: onToggleFullscreen!,
                ),
            ],
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

/// Live DVR bar: the `● LIVE` pill and a `-m:ss` behind-live label over a seek
/// bar that spans the whole DVR window. Dragging to the far right lands at the
/// live edge (behind-live → `LIVE`). Carries the same bottom-right corner
/// fullscreen toggle as [_VodBottomBar].
class _LiveDvrBottomBar extends StatelessWidget {
  const _LiveDvrBottomBar({
    required this.position,
    required this.duration,
    required this.dragValue,
    required this.onChanged,
    required this.onChangeEnd,
    required this.isFullscreen,
    required this.onToggleFullscreen,
  });

  final Duration position;
  final Duration duration;
  final double? dragValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool isFullscreen;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final positionMs = position.inMilliseconds.clamp(0, totalMs).toDouble();
    final sliderValue = dragValue ?? positionMs;
    final behind = Duration(
      milliseconds: (totalMs - sliderValue).round().clamp(0, totalMs),
    );
    final atLiveEdge = behind < const Duration(seconds: 5);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
            value: sliderValue.clamp(0.0, totalMs.toDouble()),
            max: totalMs.toDouble(),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            children: [
              const LivePill(),
              if (!atLiveEdge) ...[
                const SizedBox(width: 8),
                Text(formatBehindLive(behind),
                    style: _VodBottomBar._labelStyle),
              ],
              const Spacer(),
              if (onToggleFullscreen != null)
                _FullscreenButton(
                  isFullscreen: isFullscreen,
                  onTap: onToggleFullscreen!,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// LIVE pill (bottom-left) + corner fullscreen toggle (bottom-right). No seek
/// bar — shown for a live stream whose DVR window isn't known (or too short).
class _LiveBottomBar extends StatelessWidget {
  const _LiveBottomBar({
    required this.showLivePill,
    required this.isFullscreen,
    required this.onToggleFullscreen,
  });

  final bool showLivePill;
  final bool isFullscreen;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        children: [
          if (showLivePill) const LivePill(),
          const Spacer(),
          if (onToggleFullscreen != null)
            _FullscreenButton(
              isFullscreen: isFullscreen,
              onTap: onToggleFullscreen!,
            ),
        ],
      ),
    );
  }
}

/// Small quality control pinned to the overlay's top-right corner for
/// multi-quality video (fullscreen and inline). Opens the [_QualityDialog].
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
          // 10px padding + 24px icon → ~44px comfortable corner tap target.
          padding: EdgeInsets.all(10),
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

/// Compact centered dialog listing "Auto" + each distinct video quality.
/// Returns the chosen [VideoQuality] (or [VideoQuality.auto] for Auto) on tap,
/// and closes immediately so the selection applies at once. Works identically
/// in inline portrait and fullscreen landscape (unlike a bottom sheet).
class _QualityDialog extends StatelessWidget {
  const _QualityDialog({required this.qualities, required this.selectedId});

  final List<VideoQuality> qualities;
  final String selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      child: ConstrainedBox(
        // Cap the height so a long variant list scrolls instead of overflowing
        // a short landscape viewport.
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Calitate video',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  _QualityTile(
                    label: 'Auto',
                    selected: selectedId == 'auto',
                    onTap: () =>
                        Navigator.of(context).pop(VideoQuality.auto),
                  ),
                  for (final q in qualities)
                    _QualityTile(
                      label: q.label,
                      selected: q.id == selectedId,
                      onTap: () => Navigator.of(context).pop(q),
                    ),
                ],
              ),
            ),
          ],
        ),
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
          // 10px padding + 24px icon → ~44px comfortable corner tap target.
          padding: const EdgeInsets.all(10),
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
                      left: onLeft ? Radius.zero : const Radius.circular(1000),
                      right: onLeft ? const Radius.circular(1000) : Radius.zero,
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

/// Composes [PlayerVideoSurface] with [VideoOverlayControls] and owns the
/// fullscreen route.
///
/// This is the widget the full player embeds for video (TV channels and video
/// playlist items). It reads the reactive streams straight off [videoService].
/// Since video_player has no built-in fullscreen (unlike media_kit), fullscreen
/// is a plain opaque route this widget pushes: it renders the SAME
/// [VideoPlaybackService] controller (video_player shares one texture across
/// widgets) with the overlay in its fullscreen layout, and enters landscape
/// immersive chrome for the route's lifetime.
class VideoPlayerStage extends StatefulWidget {
  const VideoPlayerStage({
    super.key,
    required this.videoService,
    required this.title,
    required this.onPlay,
    required this.onPause,
    this.isLive = false,
    this.onSeek,
    this.fallbackDuration,
    this.allowFullscreen = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  final VideoPlaybackService videoService;
  final String title;
  final bool isLive;

  /// Known total length for VOD when the player hasn't reported one yet (e.g.
  /// the playlist item's `duration_seconds`). Enables the seek bar immediately.
  final Duration? fallbackDuration;

  final VoidCallback onPlay;
  final VoidCallback onPause;
  final ValueChanged<Duration>? onSeek;
  final bool allowFullscreen;
  final BorderRadius borderRadius;

  @override
  State<VideoPlayerStage> createState() => _VideoPlayerStageState();
}

class _VideoPlayerStageState extends State<VideoPlayerStage> {
  bool _fullscreenOpen = false;

  VideoOverlayControls _overlay({
    required bool isFullscreen,
    required VoidCallback? onToggleFullscreen,
  }) {
    final vs = widget.videoService;
    return VideoOverlayControls(
      playingStream: vs.playingStream,
      initialPlaying: vs.isPlaying,
      bufferingStream: vs.bufferingStream,
      initialBuffering: vs.isBuffering,
      positionStream: vs.positionStream,
      initialPosition: vs.position,
      durationStream: vs.durationStream,
      initialDuration: vs.duration,
      fallbackDuration: widget.fallbackDuration,
      title: widget.title,
      isLive: widget.isLive,
      isFullscreen: isFullscreen,
      onPlay: widget.onPlay,
      onPause: widget.onPause,
      onSeek: widget.onSeek,
      onToggleFullscreen: onToggleFullscreen,
      qualitiesStream: vs.qualitiesStream,
      initialQualities: vs.qualities,
      selectedQualityStream: vs.selectedQualityStream,
      initialSelectedQuality: vs.selectedQuality,
      onSelectQuality: vs.setVideoQuality,
    );
  }

  Future<void> _enterFullscreen() async {
    if (_fullscreenOpen) return;
    _fullscreenOpen = true;
    await enterVideoFullscreenChrome();
    if (!mounted) {
      await exitVideoFullscreenChrome();
      _fullscreenOpen = false;
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: Colors.black,
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        pageBuilder: (_, __, ___) => _FullscreenVideoRoute(
          videoService: widget.videoService,
          overlayBuilder: (pop) =>
              _overlay(isFullscreen: true, onToggleFullscreen: pop),
        ),
      ),
    );
    await exitVideoFullscreenChrome();
    _fullscreenOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    return PlayerVideoSurface(
      videoService: widget.videoService,
      fit: BoxFit.contain,
      borderRadius: widget.borderRadius,
      controls: (ctx) => _overlay(
        isFullscreen: false,
        onToggleFullscreen: widget.allowFullscreen ? _enterFullscreen : null,
      ),
    );
  }
}

/// The fullscreen video page: the same [videoService] controller rendered
/// edge-to-edge on black with the overlay in its fullscreen layout. The overlay
/// receives a [pop] callback (wired to its fullscreen-exit button and pinch-in
/// gesture) that pops this route.
class _FullscreenVideoRoute extends StatelessWidget {
  const _FullscreenVideoRoute({
    required this.videoService,
    required this.overlayBuilder,
  });

  final VideoPlaybackService videoService;
  final Widget Function(VoidCallback pop) overlayBuilder;

  @override
  Widget build(BuildContext context) {
    void pop() {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: PlayerVideoSurface(
        videoService: videoService,
        fit: BoxFit.contain,
        borderRadius: BorderRadius.zero,
        controls: (ctx) => overlayBuilder(pop),
      ),
    );
  }
}
