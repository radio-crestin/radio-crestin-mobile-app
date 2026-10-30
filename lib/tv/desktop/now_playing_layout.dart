import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How the desktop now-playing panel arranges itself in the room it has:
/// the artwork (or video) and the details, then the recent songs and
/// "Despre stație".
///
/// Pure, so the sizing holds from the smallest window (760 x 560) to a
/// full screen and can be unit tested.
@immutable
class DesktopNowPlayingLayout {
  const DesktopNowPlayingLayout({
    required this.stacked,
    required this.horizontalPadding,
    required this.mediaWidth,
    required this.mediaHeight,
    required this.detailsWidth,
    required this.infoSideBySide,
  });

  /// Below this width the artwork sits above the details instead of
  /// beside them.
  static const double stackBelowWidth = 600;

  /// The artwork never gets smaller or larger than these.
  static const double minArtwork = 160;
  static const double maxArtwork = 300;

  /// Largest artwork when it sits above the details, so they stay in view.
  static const double maxStackedArtwork = 280;

  /// Gap between the artwork and the details beside it.
  static const double gap = 28;

  /// Share of the row the artwork takes beside the details.
  static const double artworkShare = 0.30;

  /// Share of the row a 16:9 video takes beside the details.
  static const double videoShare = 0.55;

  /// Largest video beside the details.
  static const double maxVideoWidth = 640;

  /// Room the padding above and below the content takes.
  static const double chromeHeight = 40;

  /// Room the details take under a stacked artwork.
  static const double stackedDetailsHeight = 400;

  /// Widest the content gets; a wider panel centers it.
  static const double maxContentWidth = 1100;

  /// Width from which the recent songs and "Despre stație" sit side by
  /// side rather than one under the other.
  static const double infoSideBySideWidth = 820;

  /// Widest "Despre stație" gets alone on its row, so its description's
  /// lines stay short enough to read.
  static const double maxAboutWidth = 600;

  /// Whether the artwork sits above the details.
  final bool stacked;

  /// Padding on both sides of the content.
  final double horizontalPadding;

  /// Size of the artwork, or of the 16:9 live video in video mode.
  final double mediaWidth;
  final double mediaHeight;

  /// Width of the details column (song, controls, actions).
  final double detailsWidth;

  /// Whether the recent songs and "Despre stație" sit side by side.
  final bool infoSideBySide;
}

/// Computes the [DesktopNowPlayingLayout] for a panel at most [width] wide
/// and [height] tall, showing a square artwork or, with [isVideo], a 16:9
/// live video.
///
/// Every clamp keeps its upper bound at or above its lower one, so even a
/// degenerate size (a window laid out at zero) never throws.
DesktopNowPlayingLayout computeDesktopNowPlayingLayout({
  required double width,
  required double height,
  bool isVideo = false,
}) {
  const minArtwork = DesktopNowPlayingLayout.minArtwork;
  final stacked = width < DesktopNowPlayingLayout.stackBelowWidth;
  final padding = stacked ? 20.0 : 28.0;
  final inner = math.max(0.0, width - 2 * padding);
  final roomAbove = height - DesktopNowPlayingLayout.chromeHeight;

  if (stacked) {
    final byHeight = roomAbove - DesktopNowPlayingLayout.stackedDetailsHeight;
    final artwork = _clamp(math.min(inner, byHeight), minArtwork,
        DesktopNowPlayingLayout.maxStackedArtwork);
    final videoWidth = math.max(minArtwork, inner);
    return DesktopNowPlayingLayout(
      stacked: true,
      horizontalPadding: padding,
      mediaWidth: isVideo ? videoWidth : artwork,
      mediaHeight: isVideo ? videoWidth * 9 / 16 : artwork,
      detailsWidth: inner,
      infoSideBySide: false,
    );
  }

  final row = math.max(0.0, inner - DesktopNowPlayingLayout.gap);
  final double mediaWidth;
  final double mediaHeight;
  if (isVideo) {
    mediaWidth = _clamp(
      math.min(row * DesktopNowPlayingLayout.videoShare, roomAbove * 16 / 9),
      minArtwork,
      DesktopNowPlayingLayout.maxVideoWidth,
    );
    mediaHeight = mediaWidth * 9 / 16;
  } else {
    mediaWidth = _clamp(
      math.min(row * DesktopNowPlayingLayout.artworkShare, roomAbove),
      minArtwork,
      DesktopNowPlayingLayout.maxArtwork,
    );
    mediaHeight = mediaWidth;
  }
  final details = math.max(0.0, row - mediaWidth);
  return DesktopNowPlayingLayout(
    stacked: false,
    horizontalPadding: padding,
    mediaWidth: mediaWidth,
    mediaHeight: mediaHeight,
    detailsWidth: details,
    infoSideBySide: width >= DesktopNowPlayingLayout.infoSideBySideWidth,
  );
}

/// [value] within `[lower, upper]`, with [upper] floored at [lower].
double _clamp(double value, double lower, double upper) =>
    value.clamp(lower, math.max(lower, upper)).toDouble();
