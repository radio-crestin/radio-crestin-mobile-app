import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

class AnimatedPlayButton extends StatefulWidget {
  final Stream<PlaybackState> playbackStateStream;
  final double iconSize;
  final Color iconColor;
  final Color? backgroundColor;
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
///
/// The spinner shows at once for a load and goes at once. Buffering while
/// playing shows it only once it lasted [_bufferingSpinnerDelay]: on iOS
/// every play(), a resume too, buffers ~15–130 ms before AVPlayer starts,
/// which would flash the spinner between the play and pause icons.
class AnimatedPlayButtonState extends State<AnimatedPlayButton> {
  bool _intentIsPlaying = false;
  DateTime? _intentSetAt;

  bool _streamPlaying = false;
  bool _streamLoading = false;
  // What build() shows: `_streamLoading`, delayed for buffering while
  // playing (see the class doc).
  bool _showSpinner = false;

  Timer? _graceTimer;
  Timer? _spinnerTimer;
  StreamSubscription<PlaybackState>? _subscription;

  static const _gracePeriod = Duration(seconds: 3);
  static const _bufferingSpinnerDelay = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _subscription = widget.playbackStateStream.listen(_onPlaybackState);
  }

  void _onPlaybackState(PlaybackState state) {
    final playing = state.playing;
    // The error state is the player waiting for the internet in the car
    // (AppAudioHandler.setOfflineError): still trying, as when loading.
    final connecting = state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.error;
    final loading =
        connecting || state.processingState == AudioProcessingState.buffering;

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

    _streamLoading = loading;
    final spinner =
        _delayedSpinner(immediate: !loading || connecting || !playing);

    // playbackState is re-broadcast on every player event (e.g. buffered
    // position ticks ~2x/s on live streams). Rebuild only when an input to
    // build() changed; grace-period expiry is driven by `_graceTimer`.
    final changed = playing != _streamPlaying ||
        spinner != _showSpinner ||
        intent != _intentIsPlaying ||
        intentAt != _intentSetAt;

    _streamPlaying = playing;
    _showSpinner = spinner;
    _intentIsPlaying = intent;
    _intentSetAt = intentAt;

    if (changed && mounted) setState(() {});
  }

  /// Whether to show the spinner now for `_streamLoading`: at once when
  /// [immediate], else once the stream held it for [_bufferingSpinnerDelay].
  bool _delayedSpinner({required bool immediate}) {
    if (immediate || _streamLoading == _showSpinner) {
      _spinnerTimer?.cancel();
      _spinnerTimer = null;
      return _streamLoading;
    }
    _spinnerTimer ??= Timer(_bufferingSpinnerDelay, () {
      _spinnerTimer = null;
      if (mounted) setState(() => _showSpinner = _streamLoading);
    });
    return _showSpinner;
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
    _spinnerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showPlaying = _inGracePeriod ? _intentIsPlaying : _streamPlaying;
    final showSpinner = _showSpinner;

    Widget content;
    if (showSpinner) {
      content = SizedBox(
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
        size: widget.iconSize,
        color: widget.iconColor,
      );
    }

    // Swaps at once, without a fade, by design.
    final glyph = SizedBox(
      width: widget.iconSize,
      height: widget.iconSize,
      child: Center(child: content),
    );

    final diameter = widget.iconSize + 16;

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
              child: Center(child: glyph),
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
          child: Center(child: glyph),
        ),
      ),
    );
  }
}
