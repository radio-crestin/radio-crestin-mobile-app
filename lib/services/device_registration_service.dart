import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../globals.dart' as globals;

/// Registers this device with our backend on every launch.
///
/// Sends an upsert of device + app details — keyed by the persistent device id,
/// which the backend stores as `AppUsers.anonymous_id` — so the dashboard always
/// reflects the latest model, OS, app version, locale, and FCM token. The public
/// IP is recorded server-side from the request; the app never sends it.
///
/// Fire-and-forget by design: [register] never throws and never blocks startup.
/// The backend performs an `update_or_create`, so calling it on every launch is
/// safe and idempotent.
class DeviceRegistrationService {
  static final DeviceRegistrationService _instance =
      DeviceRegistrationService._();
  static DeviceRegistrationService get instance => _instance;

  DeviceRegistrationService._();

  /// Collects device details and upserts them to the backend.
  ///
  /// Safe to call unawaited; any failure is logged and swallowed so a flaky
  /// network never affects the app. The next launch retries the upsert. An
  /// [client] can be injected for testing.
  Future<void> register({http.Client? client}) async {
    final deviceId = globals.deviceId;
    if (deviceId.isEmpty) return;

    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final payload = await _collect(deviceId);
      final res = await httpClient
          .post(
            Uri.parse(CONSTANTS.DEVICE_REGISTER_URL),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        developer.log('Device registration failed: HTTP ${res.statusCode}');
      }
    } catch (e) {
      // Offline / transient — the next launch retries the upsert.
      developer.log('Device registration failed: $e');
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  /// Gathers platform-specific device details into the upsert payload.
  Future<Map<String, dynamic>> _collect(String deviceId) async {
    final info = DeviceInfoPlugin();
    final now = DateTime.now();
    final view = ui.PlatformDispatcher.instance.implicitView;
    final screen = <String, dynamic>{
      if (view != null) 'screen_physical_width': view.physicalSize.width,
      if (view != null) 'screen_physical_height': view.physicalSize.height,
      if (view != null) 'pixel_ratio': view.devicePixelRatio,
    };

    String? osVersion;
    String? deviceModel;
    String? manufacturer;
    bool? isPhysical;
    final extra = <String, dynamic>{...screen};
    var platform = Platform.operatingSystem;

    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      platform = 'android';
      osVersion = a.version.release;
      deviceModel = a.model;
      manufacturer = a.manufacturer;
      isPhysical = a.isPhysicalDevice;
      extra.addAll({
        'brand': a.brand,
        'product': a.product,
        'device': a.device,
        'sdk_int': a.version.sdkInt,
        'supported_abis': a.supportedAbis,
      });
    } else if (Platform.isIOS) {
      final i = await info.iosInfo;
      platform = 'ios';
      osVersion = i.systemVersion;
      deviceModel = i.utsname.machine; // e.g. "iPhone15,2"
      manufacturer = 'Apple';
      isPhysical = i.isPhysicalDevice;
      extra.addAll({
        'brand': 'Apple',
        'marketing_name': i.model, // "iPhone"
      });
    } else {
      osVersion = Platform.operatingSystemVersion;
    }

    return buildPayload(
      deviceId: deviceId,
      platform: platform,
      appVersion: globals.appVersion,
      buildNumber: globals.buildNumber,
      locale: ui.PlatformDispatcher.instance.locale.toString(),
      timezone: now.timeZoneName,
      timezoneOffsetMinutes: now.timeZoneOffset.inMinutes,
      osVersion: osVersion,
      deviceModel: deviceModel,
      manufacturer: manufacturer,
      isPhysicalDevice: isPhysical,
      fcmToken: globals.fcmToken,
      extra: extra,
    );
  }

  /// Assembles the registration payload. Pure and side-effect free so it can be
  /// unit tested without platform channels.
  ///
  /// Known fields map to dedicated backend columns; [extra] carries the long
  /// tail, which the backend keeps in a JSON column. An empty [fcmToken] is
  /// omitted so the upsert never clears a previously stored one.
  static Map<String, dynamic> buildPayload({
    required String deviceId,
    required String platform,
    required String appVersion,
    required String buildNumber,
    required String locale,
    required String timezone,
    required int timezoneOffsetMinutes,
    String? osVersion,
    String? deviceModel,
    String? manufacturer,
    bool? isPhysicalDevice,
    String? fcmToken,
    Map<String, dynamic> extra = const {},
  }) {
    return <String, dynamic>{
      'device_id': deviceId,
      'platform': platform,
      if (osVersion != null) 'os_version': osVersion,
      if (deviceModel != null) 'device_model': deviceModel,
      if (manufacturer != null) 'manufacturer': manufacturer,
      if (isPhysicalDevice != null) 'is_physical_device': isPhysicalDevice,
      'app_version': appVersion,
      'build_number': buildNumber,
      'locale': locale,
      'timezone': timezone,
      'timezone_offset_minutes': timezoneOffsetMinutes,
      if (fcmToken != null && fcmToken.isNotEmpty) 'fcm_token': fcmToken,
      ...extra,
    };
  }
}
