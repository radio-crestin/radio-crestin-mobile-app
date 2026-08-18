import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:radio_crestin/theme.dart';

import '../services/video_playback_service.dart';
import 'player_video_surface.dart';
import 'video_controls_visibility.dart';

// Control-visibility timing and the show/hide rule are shared with the TV
// chrome; re-exported so this file stays the one import a video surface needs.
export 'video_controls_visibility.dart';

/// Diameter of the central play/pause control on the video overlay.
const double kOverlayPlayButtonSize = 56.0;

/// Seconds a single double-tap seek jumps (YouTube-style).
const int kDoubleTapSeekSeconds = 10;

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
///   - VOD (`onSeek != null`, not [isLive]/indefinite) with a plausible length
///     shows a thin brand seek bar with elapsed/total labels, a fullscreen
///     button, and double-tap ±10s seeking.
///   - Live TV — and anything else the engine gives no timeline for — shows the
///     `● LIVE` pill and NO scrubber, ever. Neither AVPlayer nor ExoPlayer can
///     honour a seek inside a live window (every target clamps to its start),
///     so a draggable thumb there was an affordance that could not keep its
///     promise. Double-tap seeking is off for the same reason.
///   - Releasing the scrubber keeps the thumb at the target and shows the
///     spinner until the engine reports the seek settled ([seekingStream]),
///     rather than snapping back to a position the engine has not left yet.
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
    this.indefiniteStream,
    this.initialIndefinite = false,
    this.seekingStream,
    this.initialSeeking = false,
    this.onSeek,
    this.onToggleFullscreen,
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

  /// Whether the media has NO usable timeline, straight from
  /// [VideoPlaybackService.indefiniteStream].
  ///
  /// This is the ONLY thing that decides whether a scrubber can exist — the
  /// overlay never infers "this is live" from a duration of its own. A live
  /// stream gets no scrubber at any window length: the engines cannot honour a
  /// seek inside one (every target clamps to the start), so a draggable thumb
  /// was an affordance that could not keep its promise.
  final Stream<bool>? indefiniteStream;
  final bool initialIndefinite;

  /// Whether a seek is in flight ([VideoPlaybackService.seekingStream]).
  /// While true the thumb stays at the target the user released it on and the
  /// buffering spinner shows, instead of snapping back to a stale position.
  final Stream<bool>? seekingStream;
  final bool initialSeeking;

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

  @override
  State<VideoOverlayControls> createState() => _VideoOverlayControlsState();
}

class _VideoOverlayControlsState extends State<VideoOverlayControls>
    with SingleTickerProviderStateMixin {
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _playing = false;
  bool _buffering = false;
  bool _indefinite = false;
  bool _seeking = false;
  Duration _position = Duration.zero;
  Duration? _duration;

  /// The inactivity timer's state (also flipped by the user's surface taps).
  /// The effective visibility ([_effectiveVisible]) additionally forces the
  /// controls on while paused or buffering.
  bool _visible = true;
  Timer? _hideTimer;

  /// Optimistic play/pause shown instantly on tap until the stream confirms.
  bool? _optimisticPlaying;

  /// In-flight seek-bar drag value (ms). While set, position stream updates
  /// are ignored so the thumb tracks the finger — and it STAYS set after the
  /// release until the engine confirms the seek landed, so the thumb never
  /// snaps back to a stale position (see [_onSeekEnd]).
  double? _dragValue;

  /// Hard cap on holding the thumb at a released seek target, in case the
  /// engine never reports the seek settling.
  Timer? _seekHoldTimer;

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

  /// Whether this media can be seeked at all — the gate for double-tap ±10s.
  /// Live and otherwise-timeline-less media can not.
  bool get _seekable =>
      !widget.isLive && !_indefinite && widget.onSeek != null;

  /// Whether to draw the scrubber: a seekable media whose length is known.
  /// Without a plausible length a slider has no scale to draw, so the bottom
  /// bar keeps just its labels and the fullscreen toggle.
  bool get _showScrubber =>
      _seekable && isPlausibleMediaDuration(_effectiveDuration);

  /// The stream-reported duration when it is PLAUSIBLE, else the caller's
  /// [VideoOverlayControls.fallbackDuration] so the seek bar works immediately.
  ///
  /// The engine's indefinite-duration artefact is not a real media length (a
  /// live stream arrives as 1ms — see [kIndefiniteDurationSentinel]); honouring
  /// it pinned the scrubber thumb at the end, showed 0:00/0:00 and turned every
  /// drag into a seek back to the start.
  Duration? get _effectiveDuration {
    final d = _duration;
    if (isPlausibleMediaDuration(d)) return d;
    return widget.fallbackDuration;
  }

  /// What the user should read as "loading": the engine waiting on data, or a
  /// seek that has not landed yet.
  bool get _showSpinner => _buffering || _seeking;

  bool get _effectiveVisible => shouldShowVideoControls(
        userVisible: _visible,
        playing: _playing,
        buffering: _showSpinner,
      );

  @override
  void initState() {
    super.initState();
    _playing = widget.initialPlaying;
    _buffering = widget.initialBuffering;
    _indefinite = widget.initialIndefinite;
    _seeking = widget.initialSeeking;
    _position = widget.initialPosition;
    _duration = widget.initialDuration;

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
    final indefiniteStream = widget.indefiniteStream;
    if (indefiniteStream != null) {
      _subs.add(indefiniteStream.listen((v) {
        if (mounted) setState(() => _indefinite = v);
      }));
    }
    final seekingStream = widget.seekingStream;
    if (seekingStream != null) {
      _subs.add(seekingStream.listen(_onSeeking));
    }

    if (_playing && !_showSpinner) _scheduleHide();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _seekHoldTimer?.cancel();
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
    if (_showSpinner) {
      _hideTimer?.cancel();
    } else if (_playing) {
      _scheduleHide();
    }
  }

  /// The engine's answer to a released seek: while it is still in flight the
  /// thumb stays at the target; once it lands the real position takes over.
  void _onSeeking(bool seeking) {
    if (!mounted) return;
    setState(() => _seeking = seeking);
    if (seeking) {
      _hideTimer?.cancel();
    } else {
      _releaseSeekHold();
      if (_playing) _scheduleHide();
    }
  }

  /// Hands the thumb back to the position stream.
  void _releaseSeekHold() {
    _seekHoldTimer?.cancel();
    _seekHoldTimer = null;
    if (mounted && _dragValue != null) setState(() => _dragValue = null);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHideDelay, () {
      if (mounted && _playing && !_showSpinner && _dragValue == null) {
        setState(() => _visible = false);
      }
    });
  }

  /// A tap on the video surface: hidden controls come back (and the inactivity
  /// countdown restarts), visible controls step aside (YouTube-style toggle).
  void _onSurfaceTap() {
    setState(() => _visible = !_visible);
    if (_visible && _playing && !_showSpinner) _scheduleHide();
  }

  /// Keeps the controls up and restarts the inactivity countdown after a
  /// deliberate interaction (fullscreen toggle, quality pick, scrub).
  void _noteInteraction() {
    if (!_visible) setState(() => _visible = true);
    if (_playing && !_showSpinner) _scheduleHide();
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

  /// The user let go of the scrubber.
  ///
  /// The thumb STAYS at the target — the engine keeps streaming its old
  /// position for a moment after a seek, and clearing the drag value here is
  /// what used to yank the thumb backwards right after the release. It is
  /// handed back to the position stream by [_onSeeking] when the engine
  /// confirms the seek landed, or by [_seekHoldTimeout] if it never does.
  void _onSeekEnd(double v) {
    final target = Duration(milliseconds: v.round());
    widget.onSeek?.call(target);
    setState(() {
      _position = target;
      _dragValue = v;
    });
    if (widget.seekingStream == null) {
      // No settling signal to wait for (YouTube surfaces): the old immediate
      // hand-back is the best available.
      _releaseSeekHold();
    } else {
      _seekHoldTimer?.cancel();
      _seekHoldTimer = Timer(_seekHoldTimeout, _releaseSeekHold);
    }
    if (_playing) _scheduleHide();
  }

  /// Longest the thumb is pinned to a released target without the engine
  /// confirming anything.
  static const Duration _seekHoldTimeout = Duration(seconds: 5);

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
                      showScrubber: _showScrubber,
                      isFullscreen: widget.isFullscreen,
                      showPlaying: showPlaying,
                      buffering: _showSpinner,
                      position: _position,
                      duration: _effectiveDuration,
                      dragValue: _dragValue,
                      onTogglePlay: _togglePlay,
                      onSeekChanged: (v) {
                        _hideTimer?.cancel();
                        setState(() => _dragValue = v);
                      },
                      onSeekEnd: _onSeekEnd,
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
/// Corner layout mirrors YouTube's convention: the enter/exit-fullscreen button
/// sits in the BOTTOM-RIGHT corner, below the seek line, and is ALWAYS there —
/// it replaced the quality selector, which offered a choice the adaptive
/// stream already makes better than a person can.
class _ControlsLayer extends StatelessWidget {
  const _ControlsLayer({
    required this.title,
    required this.isLive,
    required this.showScrubber,
    required this.isFullscreen,
    required this.showPlaying,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.dragValue,
    required this.onTogglePlay,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onToggleFullscreen,
  });

  final String title;
  final bool isLive;
  final bool showScrubber;
  final bool isFullscreen;
  final bool showPlaying;
  final bool buffering;
  final Duration position;
  final Duration? duration;
  final double? dragValue;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        // Top row: fullscreen carries the title; inline shows nothing — the
        // playlist section already shows the item title below the video.
        if (isFullscreen)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 0),
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
          child: showScrubber
              ? _VodBottomBar(
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
    return OverlayCircleButton(
      onTap: onTap,
      semanticLabel: showPlaying ? 'Pauză' : 'Redă',
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
                showPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(showPlaying),
                color: Colors.white,
                size: kOverlayPlayButtonSize * 0.62,
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
    final maxValue = totalMs.toDouble();
    final elapsed = formatOverlayTime(Duration(milliseconds: sliderValue.round()));
    final total = formatOverlayTime(duration);

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
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
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

/// Enter/exit fullscreen — the overlay's permanent bottom-right control.
///
/// Deliberately the SAME disc as [_PlayPauseButton]: it took over the corner
/// the quality picker used to occupy, and reading as a peer of the transport
/// (rather than a small secondary glyph) is what makes it findable at a glance.
class _FullscreenButton extends StatelessWidget {
  const _FullscreenButton({required this.isFullscreen, required this.onTap});

  final bool isFullscreen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OverlayCircleButton(
      onTap: onTap,
      semanticLabel: isFullscreen ? 'Ieși din ecran complet' : 'Ecran complet',
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        transitionBuilder: _uniqueFade,
        child: Icon(
          isFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          key: ValueKey(isFullscreen),
          color: Colors.white,
          size: kOverlayPlayButtonSize * 0.55,
        ),
      ),
    );
  }
}

/// The overlay's one button shape: a translucent circular disc with a white
/// rounded glyph, so play/pause, skip and fullscreen all read as one family.
class OverlayCircleButton extends StatelessWidget {
  const OverlayCircleButton({
    super.key,
    required this.child,
    required this.onTap,
    this.size = kOverlayPlayButtonSize,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback onTap;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.black.withValues(alpha: 0.32),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(width: size, height: size, child: child),
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
      indefiniteStream: vs.indefiniteStream,
      initialIndefinite: vs.isIndefinite,
      seekingStream: vs.seekingStream,
      initialSeeking: vs.isSeeking,
      isFullscreen: isFullscreen,
      onPlay: widget.onPlay,
      onPause: widget.onPause,
      onSeek: widget.onSeek,
      onToggleFullscreen: onToggleFullscreen,
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
