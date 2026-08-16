import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'animated_play_button.dart';

/// Responsive sizing for the full-screen player, derived from the screen size.
@immutable
class PlayerLayoutMetrics {
  /// Side length of the square station artwork.
  final double thumbSize;

  /// Diameter of the central play/pause control.
  final double playIconSize;

  /// Diameter of the skip-forward / skip-back controls.
  final double skipIconSize;

  /// Horizontal gap between the play control and the skip controls.
  final double skipSpacing;

  const PlayerLayoutMetrics({
    required this.thumbSize,
    required this.playIconSize,
    required this.skipIconSize,
    required this.skipSpacing,
  });
}

/// Computes the responsive player layout from the current screen size.
///
/// Pure and side-effect free so the sizing math can be unit tested. The
/// artwork grows with the available panel height but is bounded both by a
/// fixed `[140, 300]` range and by the usable width.
///
/// Guards the degenerate case where the panel is laid out before the window
/// has real dimensions (`MediaQuery.size == Size.zero`, common on iOS during
/// launch / return-from-background). There `maxThumbWidth` becomes negative;
/// previously `(...).clamp(140.0, maxThumbWidth)` threw
/// `ArgumentError: Invalid argument(s): 140.0` whenever the upper limit fell
/// below the 140 lower limit — the single highest-volume crash in production
/// (PostHog issue 019d8f95…, 1100+ occurrences). Clamping the upper bound to a
/// 140 floor keeps `clamp` well-formed.
PlayerLayoutMetrics computePlayerLayout({
  required double screenWidth,
  required double screenHeight,
  required double textScale,
}) {
  final scale = textScale.clamp(1.0, 1.5);
  final panelHeight = screenHeight * 0.9;

  // Fixed elements budget: drag handle(7) + title(~30) + song+artist(~50)
  //   + chips(~50) + transport(~90) + bottom row(~75) + spacers(~110) + bottom(~24)
  final fixedBudget = 420.0 * scale;

  // The artwork must also fit horizontally with 32px padding on each side.
  // The upper bound is floored at 140 so it can never drop below the lower
  // bound and make num.clamp throw.
  final maxThumbWidth = (screenWidth - 64.0).clamp(140.0, double.infinity);
  final thumbSize = (panelHeight - fixedBudget)
      .clamp(140.0, 300.0)
      .clamp(140.0, maxThumbWidth)
      .toDouble();

  // Smoothly interpolate transport controls based on available thumb space.
  // t=0 at thumbSize 140, t=1 at thumbSize 240+.
  final t = ((thumbSize - 140.0) / 100.0).clamp(0.0, 1.0).toDouble();

  return PlayerLayoutMetrics(
    thumbSize: thumbSize,
    playIconSize: 48.0 + 14.0 * t, // 48..62
    skipIconSize: 36.0 + 10.0 * t, // 36..46
    skipSpacing: 20.0 + 12.0 * t, // 20..32
  );
}

/// Reads the player metrics from [context]'s `MediaQuery`.
///
/// The single entry point every player layout uses, so the radio full player
/// and the playlist / video player can never end up with differently sized
/// transport controls.
PlayerLayoutMetrics playerLayoutOf(BuildContext context) => computePlayerLayout(
      screenWidth: MediaQuery.of(context).size.width,
      screenHeight: MediaQuery.of(context).size.height,
      textScale: MediaQuery.textScalerOf(context).scale(1.0),
    );

/// Extra padding [AnimatedPlayButton] adds around its icon (its ring).
const double kPlayButtonRingPadding = 16.0;

/// Extra padding [PlayerSkipButton] adds around its icon (its tap target).
const double kSkipButtonPadding = 20.0;

/// Height the transport row occupies for [metrics] — driven by its tallest
/// control. Callers reserve exactly this so the row is never clipped and the
/// cluster keeps a fixed vertical position.
double playerTransportRowHeight(PlayerLayoutMetrics metrics) => math.max(
      metrics.playIconSize + kPlayButtonRingPadding,
      metrics.skipIconSize + kSkipButtonPadding,
    );

/// Round previous / next control: an icon of [iconSize] inside a 10px ring, so
/// the tap target is `iconSize + 20` on a side.
class PlayerSkipButton extends StatelessWidget {
  const PlayerSkipButton({
    super.key,
    required this.icon,
    required this.iconSize,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final double iconSize;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(kSkipButtonPadding / 2),
        child: Icon(icon, size: iconSize, color: color),
      ),
    );
  }
}

/// The prev | play/pause | next cluster shared by EVERY full player — the
/// classic radio layout ([FullAudioPlayer]) and the playlist / video layout
/// ([PlaylistPlayerSection]) alike.
///
/// Both get their sizes from the same [PlayerLayoutMetrics], so the control the
/// user reaches for blind is the exact same size (and, together with the
/// bottom-anchored slots around it, in the same place) whatever kind of station
/// is playing. Secondary controls specific to one layout (repeat, quality,
/// fullscreen) go in [leading] / [trailing] and never touch the trio's metrics.
class PlayerTransportControls extends StatelessWidget {
  const PlayerTransportControls({
    super.key,
    required this.metrics,
    required this.playbackStateStream,
    required this.playButtonKey,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    required this.onPrevious,
    required this.onNext,
    this.leading = const <Widget>[],
    this.trailing = const <Widget>[],
    this.secondarySpacing = 6.0,
    this.alignStart = false,
  });

  final PlayerLayoutMetrics metrics;
  final Stream<PlaybackState> playbackStateStream;
  final GlobalKey<AnimatedPlayButtonState> playButtonKey;

  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// Layout-specific controls left / right of the trio (already balanced by the
  /// caller when it wants the trio dead-centered).
  final List<Widget> leading;
  final List<Widget> trailing;

  /// Gap between the trio and the [leading] / [trailing] controls. Tighter than
  /// [PlayerLayoutMetrics.skipSpacing] so a row with secondary controls still
  /// fits a narrow phone.
  final double secondarySpacing;

  /// Left-aligns the cluster (the landscape right-hand column) instead of
  /// centering it.
  final bool alignStart;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    // [BoxFit.scaleDown] is a pure safety net: it never enlarges, so on every
    // real screen the controls render at exactly their metric sizes. It only
    // engages on a pathologically narrow window, where shrinking beats a
    // clipped (and therefore untappable) control.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignStart ? Alignment.centerLeft : Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final w in leading) ...[w, SizedBox(width: secondarySpacing)],
          PlayerSkipButton(
            icon: Icons.skip_previous_rounded,
            iconSize: metrics.skipIconSize,
            color: onSurface,
            onTap: () {
              playButtonKey.currentState?.notifyWillPlay();
              onPrevious();
            },
          ),
          SizedBox(width: metrics.skipSpacing),
          AnimatedPlayButton(
            key: playButtonKey,
            playbackStateStream: playbackStateStream,
            iconSize: metrics.playIconSize,
            iconColor: Theme.of(context).colorScheme.onPrimary,
            backgroundColor: Theme.of(context).bottomAppBarTheme.color,
            onPlay: onPlay,
            onPause: onPause,
            onStop: onStop,
          ),
          SizedBox(width: metrics.skipSpacing),
          PlayerSkipButton(
            icon: Icons.skip_next_rounded,
            iconSize: metrics.skipIconSize,
            color: onSurface,
            onTap: () {
              playButtonKey.currentState?.notifyWillPlay();
              onNext();
            },
          ),
          for (final w in trailing) ...[SizedBox(width: secondarySpacing), w],
        ],
      ),
    );
  }
}
