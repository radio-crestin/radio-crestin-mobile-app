import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../widgets/song_history_modal.dart';
import 'now_playing_controls.dart';

/// Shows the songs [stationSlug] played lately, as the phone's "istoric"
/// does, in a dialog centered over the window rather than a sheet rising
/// from its bottom. Esc, the close button or a click outside closes it.
Future<void> showDesktopSongHistory(
  BuildContext context, {
  required String stationSlug,
  String? stationThumbnailUrl,
  DateTime Function()? playedCutoff,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    // Named so PostHog records a `$screen` for it, as for the pages.
    routeSettings: const RouteSettings(name: '/song-history'),
    builder: (dialogContext) {
      final window = MediaQuery.sizeOf(dialogContext);
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 560,
          height: math.max(240.0, math.min(760.0, window.height - 48)),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: NowPlayingPalette.edge),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SongHistoryModal(
                stationSlug: stationSlug,
                stationThumbnailUrl: stationThumbnailUrl,
                playedCutoff: playedCutoff,
              ),
            ),
          ),
        ),
      );
    },
  );
}
