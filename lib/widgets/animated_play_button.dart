import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

class AnimatedPlayButton extends StatefulWidget {
  final Stream<PlaybackState> playbackStateStream;
  final double iconSize;
  final Color iconColor;
  final Color? backgroundColor;

  /// Diameter of the button; [iconSize] plus 16 when null.
  final double? size;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;

  const AnimatedPlayButton({
    super.key,
    required this.playbackStateStream,
    required this.iconSize,
    required this.iconColor,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    this.backgroundColor,
    this.size,
  });

  @override
  AnimatedPlayButtonState createState() => AnimatedPlayButtonState();
}

/// The button has two layers:
///
/// 1. **User intent** — set instantly on tap/skip. This is what the UI shows.
///    It acts as an optimistic prediction that the stream will catch up.
///
/// 2. **Stream truth** — the actual playback state from audio_service.
///    After a grace period (3s), if the stream disagrees with the intent,
///    the stream wins (e.g. playback failed → show play icon, still loading → show spinner).
class AnimatedPlayButtonState extends State<AnimatedPlayButton> {
  bool _intentIsPlaying = false;
  DateTime? _intentSetAt;

  bool _streamPlaying = false;
  bool _streamLoading = false;

  Timer? _graceTimer;
  StreamSubscription<PlaybackState>? _subscription;

  static const _gracePeriod = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _subscription = widget.playbackStateStream.listen(_onPlaybackState);
  }

  void _onPlaybackState(PlaybackState state) {
    final playing = state.playing;
    final loading = state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.buffering;

    // When stream reaches a settled state, always sync intent to reality.
    // This prevents desync from programmatic play/pause (autoplay, reconnect,
    // station switch) where nobody calls notifyWillPlay/_setIntent.
    final settled = state.processingState == AudioProcessingState.ready ||
        state.processingState == AudioProcessingState.completed ||
        state.processingState == AudioProcessingState.idle;

    var intent = _intentIsPlaying;
    var intentAt = _intentSetAt;
    if (settled) {
      intent = playing;
      intentAt = null;
      _graceTimer?.cancel();
    }

    // playbackState is re-broadcast on every player event (e.g. buffered
    // position ticks ~2x/s on live streams). Rebuild only when an input to
    // build() changed; grace-period expiry is driven by `_graceTimer`.
    final changed = playing != _streamPlaying ||
        loading != _streamLoading ||
        intent != _intentIsPlaying ||
        intentAt != _intentSetAt;

    _streamPlaying = playing;
    _streamLoading = loading;
    _intentIsPlaying = intent;
    _intentSetAt = intentAt;

    if (changed && mounted) setState(() {});
  }

  /// Call this from skip next/prev buttons to set optimistic "playing" state.
  void notifyWillPlay() {
    _setIntent(true);
  }

  void _setIntent(bool playing) {
    _intentIsPlaying = playing;
    _intentSetAt = DateTime.now();
    _graceTimer?.cancel();
    _graceTimer = Timer(_gracePeriod, () {
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  bool get _inGracePeriod =>
      _intentSetAt != null &&
      DateTime.now().difference(_intentSetAt!) < _gracePeriod;

  @override
  void dispose() {
    _subscription?.cancel();
    _graceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool showPlaying;
    bool showSpinner;

    if (_inGracePeriod) {
      showPlaying = _intentIsPlaying;
      showSpinner = _streamLoading;
    } else {
      showPlaying = _streamPlaying;
      showSpinner = _streamLoading;
    }

    Widget content;
    if (showSpinner) {
      content = SizedBox(
        key: const ValueKey('loading'),
        width: widget.iconSize * 0.65,
        height: widget.iconSize * 0.65,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(widget.iconColor),
        ),
      );
    } else {
      content = Icon(
        showPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey(showPlaying),
        size: widget.iconSize,
        color: widget.iconColor,
      );
    }

    final switcher = SizedBox(
      width: widget.iconSize,
      height: widget.iconSize,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: Center(child: content),
      ),
    );

    final diameter = widget.size ?? widget.iconSize + 16;

    final VoidCallback onTap;
    if (showSpinner) {
      // During loading/buffering, tapping pauses (cancels in-flight play).
      // Previously this called onStop() which killed the player entirely,
      // making the button unresponsive after skip next.
      onTap = () { _setIntent(false); widget.onPause(); };
    } else if (showPlaying) {
      onTap = () { _setIntent(false); widget.onPause(); };
    } else {
      onTap = () { _setIntent(true); widget.onPlay(); };
    }

    if (widget.backgroundColor != null) {
      return ClipOval(
        child: Material(
          color: widget.backgroundColor!,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: diameter,
              child: Center(child: switcher),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: diameter,
          child: Center(child: switcher),
        ),
      ),
    );
  }
}
