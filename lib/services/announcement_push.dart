import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../appAudioHandler.dart';
import '../globals.dart' as globals;
import '../tv/tv_platform.dart';
import '../widgets/announcement_banner.dart';
import '../widgets/station_announcements.dart';
import 'announcement.dart';
import 'announcement_actions.dart';
import 'announcements_service.dart';

/// Opens the announcement a push names (`data: {type: announcement,
/// slug}`), whether the push was tapped with the app closed, in the
/// background, or arrived while it was open.
///
/// Phone and tablet home only: the TV, desktop and car screens never
/// attach it.
class AnnouncementPush {
  AnnouncementPush._();

  static bool _attached = false;

  /// Whether Android 13+ was asked to allow notifications already.
  static const _permissionAskedKey = 'announcements_push_permission_asked';

  /// Starts handling announcement pushes, once per launch.
  static void attach(AnnouncementsService service) {
    if (_attached || !service.pushEnabled) return;
    if (!(Platform.isAndroid || Platform.isIOS) || TvPlatform.isTV) return;
    _attached = true;
    try {
      FirebaseMessaging.onMessage.listen(
        (message) => _onForeground(message, service),
        onError: (Object _) {},
      );
      FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _onTap(message, service),
        onError: (Object _) {},
      );
      unawaited(FirebaseMessaging.instance.getInitialMessage().then((message) {
        if (message != null) unawaited(_onTap(message, service));
      }).catchError((Object e) {
        developer.log('Announcement push: no initial message: $e');
      }));
      unawaited(_askAndroidPermissionOnce());
    } catch (e) {
      developer.log('Announcement push: not attached: $e');
    }
  }

  /// The slug of an announcement push, or null for any other push.
  static String? _slugOf(RemoteMessage message) {
    final data = message.data;
    final slug = data['slug'];
    if (data['type'] != 'announcement' || slug is! String || slug.isEmpty) {
      return null;
    }
    return slug;
  }

  /// A tap on the notification: runs the announcement's button, or shows
  /// its card when it has none. A station's announcement starts the
  /// station and opens its announcements.
  static Future<void> _onTap(
    RemoteMessage message,
    AnnouncementsService service,
  ) async {
    final slug = _slugOf(message);
    if (slug == null) return;
    final item = await service.fetch(slug);
    if (item == null) return;
    if (item.placement == AnnouncementPlacement.station) {
      await _openInStation(item, service);
      return;
    }
    service.report(AnnouncementEvent.pushOpened, item, 0);
    final button = item.button;
    if (button != null) {
      await AnnouncementActions.run(item, button.action);
    } else {
      AnnouncementBanner.show(item, service);
    }
  }

  /// Plays the announcement's station (the one playing, when it is one of
  /// them) and opens that station's announcements.
  static Future<void> _openInStation(
    Announcement item,
    AnnouncementsService service,
  ) async {
    final playing =
        GetIt.instance<AppAudioHandler>().currentStation.valueOrNull?.slug;
    final slug = item.stationSlugs.contains(playing)
        ? playing
        : item.stationSlugs.firstOrNull;
    service.report(AnnouncementEvent.pushOpened, item, 0, station: slug);
    final station =
        slug == null ? null : await AnnouncementActions.findStation(slug);
    if (station == null) return;
    if (slug != playing) {
      unawaited(GetIt.instance<AppAudioHandler>()
          .playStation(station, fromFavorites: false));
    }
    final context = globals.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      await StationAnnouncementsSheet.show(context, station);
    }
  }

  /// A push while the app is open: the system shows nothing, so the card
  /// slides down over the screen instead.
  static Future<void> _onForeground(
    RemoteMessage message,
    AnnouncementsService service,
  ) async {
    final slug = _slugOf(message);
    if (slug == null) return;
    final item = await service.fetch(slug);
    if (item != null) AnnouncementBanner.show(item, service);
  }

  /// Asks Android 13+ to allow notifications, once, when Home first
  /// shows, as iOS asks at the first launch. Earlier versions allow them
  /// without asking, and the plugin then only reads the setting.
  static Future<void> _askAndroidPermissionOnce() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_permissionAskedKey) ?? false) return;
    try {
      await FirebaseMessaging.instance.requestPermission();
      await prefs.setBool(_permissionAskedKey, true);
    } catch (e) {
      developer.log('Announcement push: permission not asked: $e');
    }
  }
}
