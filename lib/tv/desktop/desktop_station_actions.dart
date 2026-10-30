import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../appAudioHandler.dart';
import '../../services/analytics_service.dart';
import '../../services/share_service.dart';
import '../../theme.dart';
import '../../types/Station.dart';
import '../../widgets/copied_toast.dart';
import '../../widgets/hide_station_dialog.dart';
import '../../widgets/share_handler.dart';
import '../tv_theme.dart';

/// What the listener can do with a station on the desktop screen, from its
/// card, its search result, the mini player or its context menu: the
/// phone's station actions, with desktop dialogs and confirmations.
class DesktopStationActions {
  DesktopStationActions(this.audioHandler);

  final AppAudioHandler audioHandler;

  /// How long sharing waits for the listener's personal link before it
  /// shares the plain one, when none was fetched before.
  static const Duration _linkWait = Duration(seconds: 2);

  /// What a hidden station's notice says, and its buttons.
  static const String hiddenNotice =
      'Stație ascunsă. O poți readuce din Setări.';
  static const String undoLabel = 'Anulează';
  static const String okLabel = 'Ok';

  /// How long the hidden station's notice stays, as on the phone.
  static const Duration hiddenNoticeDuration = Duration(seconds: 6);

  /// Whether [station] is one of the listener's favorites now.
  bool isFavorite(Station station) => audioHandler
      .stationDataService.favoriteStationSlugs.value
      .contains(station.slug);

  /// Starts [station]. [fromFavorites]: picked from the "Favorite" section,
  /// so next and previous step through the favorites, as on the phone;
  /// null keeps what they step through.
  void play(
    Station station, {
    bool? fromFavorites = false,
    required String source,
  }) {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'station_tap',
      'station_id': station.id,
      'station_slug': station.slug,
      'from_favorites': fromFavorites,
      'source': source,
    });
    unawaited(audioHandler.playStation(station, fromFavorites: fromFavorites));
  }

  /// Adds [station] to the favorites or removes it; returns whether it is
  /// one afterwards. [source] names the control, for analytics.
  bool toggleFavorite(Station station, {required String source}) {
    final favorite = audioHandler.toggleStationFavorite(station);
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'favorite_toggle',
      'station_slug': station.slug,
      'station_id': station.id,
      'is_favorite': favorite,
      'source': source,
    });
    return favorite;
  }

  /// Opens the system share picker with an invitation to [station], as the
  /// phone's share sheet words it, pointing at [origin] (global bounds).
  Future<void> share(Station station, {Rect? origin}) async {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'station_menu_share',
      'station_slug': station.slug,
      'station_id': station.id,
    });
    final url = stationLink(station, await _shareLink());
    await ShareHandler.shareViaSystem(
      shareUrl: url,
      shareMessage: url,
      stationName: station.title,
      songName: station.songTitle,
      songArtist: station.songArtist,
      sharePositionOrigin: origin,
    );
  }

  /// Copies [station]'s link, the listener's personal one when known, and
  /// confirms it with a toast above the mini player.
  Future<void> copyLink(BuildContext context, Station station) async {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'copy_share_link',
      'station_slug': station.slug,
      'station_id': station.id,
      'source': 'desktop_menu',
    });
    final url = stationLink(station, await _shareLink());
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    CopiedToast.show(
      context,
      message: 'Link copiat',
      bottom: DesktopTokens.miniPlayerHeight + 28,
    );
  }

  /// Hides [station] from every list, once the listener confirmed it for a
  /// favorite, and says so with a way to undo it.
  Future<void> hide(BuildContext context, Station station) async {
    final wasFavorite = isFavorite(station);
    if (wasFavorite && !await confirmDesktopHide(context, station)) return;
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'station_hide',
      'station_slug': station.slug,
      'station_id': station.id,
      'was_favorite': wasFavorite,
      'source': 'desktop_menu',
    });
    final favoriteIndex = audioHandler.hideStation(station);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(_hiddenSnackBar(
        station,
        favoriteIndex,
        close: messenger.hideCurrentSnackBar,
      ));
  }

  /// "Stație ascunsă", with "Anulează" and "Ok". It goes by itself after
  /// [hiddenNoticeDuration]: the buttons sit in its content, as a snack
  /// bar's own action would keep it until clicked.
  SnackBar _hiddenSnackBar(
    Station station,
    int? favoriteIndex, {
    required VoidCallback close,
  }) =>
      SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 520,
        duration: hiddenNoticeDuration,
        backgroundColor: DesktopTokens.raisedSurface,
        padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 8, 6),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: DesktopTokens.hairline),
        ),
        content: Row(
          children: [
            const Expanded(
              child: Text(
                hiddenNotice,
                style: TextStyle(color: TvColors.textPrimary, fontSize: 14),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: TvColors.primaryLight,
              ),
              onPressed: () {
                close();
                AnalyticsService.instance.capture('button_clicked', {
                  'button_name': 'station_hide_undo',
                  'station_slug': station.slug,
                  'station_id': station.id,
                });
                unawaited(audioHandler.unhideStation(
                  station,
                  favoriteIndex: favoriteIndex,
                ));
              },
              child: const Text(undoLabel),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: TvColors.textSecondary,
              ),
              onPressed: close,
              child: const Text(okLabel),
            ),
          ],
        ),
      );

  /// Shows a hidden [station] in the lists again.
  void unhide(Station station) {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'station_unhide',
      'station_slug': station.slug,
      'station_id': station.id,
      'source': 'desktop_grid',
    });
    unawaited(audioHandler.unhideStation(station));
  }

  /// [station]'s link: the listener's personal one from [data], which
  /// counts the friends who open it, else the plain one.
  static String stationLink(Station station, ShareLinkData? data) {
    final String slug = station.slug;
    if (data == null) return 'https://www.radiocrestin.ro/$slug';
    return data.generateShareUrl(stationSlug: slug, songId: station.songId);
  }

  /// The listener's personal link: the one fetched before, at once, while
  /// a fresh copy is fetched for next time; else a fresh one, if it comes
  /// within [_linkWait].
  Future<ShareLinkData?> _shareLink() async {
    final cached = ShareLinkCache.read();
    final fresh = _fetchShareLink();
    if (cached != null) return cached;
    try {
      return await fresh.timeout(_linkWait);
    } on TimeoutException {
      return null;
    }
  }

  Future<ShareLinkData?> _fetchShareLink() =>
      ShareService(audioHandler.graphqlClient).getPersonalShareLink();
}

/// Asks before hiding [station], a favorite: hiding it also takes it out of
/// the favorites. Resolves to whether the listener confirmed.
Future<bool> confirmDesktopHide(BuildContext context, Station station) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _HideFavoriteDialog(station: station),
  );
  return confirmed ?? false;
}

/// The phone's question before hiding a favorite, worded for a computer:
/// no car to mention. "Anulează", the safe choice, has the focus.
class _HideFavoriteDialog extends StatelessWidget {
  const _HideFavoriteDialog({required this.station});

  final Station station;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DesktopTokens.raisedSurface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: DesktopTokens.hairline),
      ),
      title: Text(
        HideFavoriteWording.title(station),
        style: TvTypography.title.copyWith(fontWeight: FontWeight.w700),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          HideFavoriteWording.message(),
          style: const TextStyle(
            fontSize: 14,
            height: 1.45,
            color: TvColors.textSecondary,
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          style: TextButton.styleFrom(foregroundColor: TvColors.textPrimary),
          child: const Text(HideFavoriteWording.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: Colors.white,
          ),
          child: const Text(HideFavoriteWording.hideLabel),
        ),
      ],
    );
  }
}
