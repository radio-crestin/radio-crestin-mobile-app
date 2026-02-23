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
    _streamPlaying = state.playing;
    _streamLoading =
        state.processingState == AudioProcessingState.loading ||
        state.processingState == AudioProcessingState.buffering;

    // When stream reaches a settled state, always sync intent to reality.
    // This prevents desync from programmatic play/pause (autoplay, reconnect,
    // station switch) where nobody calls notifyWillPlay/_setIntent.
    final settled = state.processingState == AudioProcessingState.ready ||
        state.processingState == AudioProcessingState.completed ||
        state.processingState == AudioProcessingState.idle;

    if (settled) {
      _intentIsPlaying = state.playing;
      _intentSetAt = null;
      _graceTimer?.cancel();
    }

    if (mounted) setState(() {});
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

    final VoidCallback onTap;
    if (showSpinner) {
      onTap = () { _setIntent(false); widget.onStop(); };
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
            child: SizedBox(
              width: widget.iconSize + 16,
              height: widget.iconSize + 16,
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
        child: SizedBox(
          width: widget.iconSize + 16,
          height: widget.iconSize + 16,
          child: Center(child: switcher),
        ),
      ),
    );
  }
}
