import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../globals.dart' as globals;

/// Decides *when* the push-notification permission prompt is shown.
///
/// The prompt is never shown at startup — a user who just opened the app has
/// no context for it. Instead every station play bumps a persisted counter and
/// the request fires exactly once, on the [playsBeforePrompt]-th play. Users
/// who already granted the permission are never asked again and keep their FCM
/// token refreshed on every launch.
class NotificationPermissionService {
  NotificationPermissionService({
    required SharedPreferences prefs,
    required Future<bool> Function() isAuthorized,
    required Future<bool> Function() requestPermission,
    required Future<void> Function() registerToken,
    this.playsBeforePrompt = 2,
    this.tokenNeedsPermission = true,
  })  : _prefs = prefs,
        _isAuthorized = isAuthorized,
        _requestPermission = requestPermission,
        _registerToken = registerToken;

  /// Wires the service to `firebase_messaging`.
  factory NotificationPermissionService.firebase(SharedPreferences prefs) {
    return NotificationPermissionService(
      prefs: prefs,
      isAuthorized: () async {
        final settings =
            await FirebaseMessaging.instance.getNotificationSettings();
        return _isGranted(settings.authorizationStatus);
      },
      requestPermission: () async {
        // `provisional: false` so the system dialog is actually shown — the
        // whole point of deferring it to the 2nd play.
        final settings = await FirebaseMessaging.instance.requestPermission(
          alert: true,
          announcement: true,
          badge: true,
          carPlay: false,
          criticalAlert: true,
          provisional: false,
          sound: true,
        );
        return _isGranted(settings.authorizationStatus);
      },
      registerToken: () async {
        await FirebaseMessaging.instance.setAutoInitEnabled(true);
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) globals.fcmToken = token;
        developer.log('FCMToken $token');
      },
      // Only iOS ties the FCM token to the notification authorization; Android
      // hands out a token regardless of the POST_NOTIFICATIONS grant.
      tokenNeedsPermission: Platform.isIOS,
    );
  }

  static const _playCountKey = 'notification_prompt_play_count';
  static const _promptedKey = 'notification_prompt_shown';
  static const _tag = 'NotificationPermissionService';

  /// Number of station plays after which the permission prompt is shown.
  final int playsBeforePrompt;

  /// Whether an FCM token can only be minted once notifications are allowed.
  final bool tokenNeedsPermission;

  final SharedPreferences _prefs;
  final Future<bool> Function() _isAuthorized;
  final Future<bool> Function() _requestPermission;
  final Future<void> Function() _registerToken;

  /// How many station plays have been counted towards the prompt.
  int get playCount => _prefs.getInt(_playCountKey) ?? 0;

  /// Whether the prompt has already been shown (or was never needed because
  /// the permission was granted before).
  bool get hasPrompted => _prefs.getBool(_promptedKey) ?? false;

  /// Startup path: never prompts. Keeps FCM working for users who already
  /// granted the permission, and marks them as prompted so the play counter
  /// can never surface a redundant dialog later.
  Future<void> initialize() async {
    final authorized = await _guardBool(_isAuthorized);
    if (authorized && !hasPrompted) {
      await _prefs.setBool(_promptedKey, true);
    }
    if (authorized || !tokenNeedsPermission) {
      await _guardToken();
    }
  }

  /// Call on every station-play action. Requests the notification permission
  /// once, on the [playsBeforePrompt]-th play, and never again.
  Future<void> onStationPlayed() async {
    if (hasPrompted) return;

    final count = playCount + 1;
    await _prefs.setInt(_playCountKey, count);
    if (count < playsBeforePrompt) return;

    // Persist first: a crash or a denied dialog must not re-prompt later.
    await _prefs.setBool(_promptedKey, true);
    final granted = await _guardBool(_requestPermission);
    if (granted) await _guardToken();
  }

  static bool _isGranted(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized ||
      status == AuthorizationStatus.provisional;

  /// Runs [probe], treating plugin failures (no Play Services, missing APNS
  /// token, …) as "not authorized" so nothing can break playback.
  Future<bool> _guardBool(Future<bool> Function() probe) async {
    try {
      return await probe();
    } catch (e, stackTrace) {
      developer.log('$_tag: $e', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  Future<void> _guardToken() async {
    try {
      await _registerToken();
    } catch (e, stackTrace) {
      developer.log('$_tag: token registration failed: $e',
          error: e, stackTrace: stackTrace);
    }
  }
}
