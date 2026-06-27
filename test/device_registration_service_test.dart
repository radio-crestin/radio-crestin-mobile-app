import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/device_registration_service.dart';
import 'package:radio_crestin/globals.dart' as globals;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceRegistrationService.buildPayload', () {
    test('includes core device + app fields and merges extras', () {
      final payload = DeviceRegistrationService.buildPayload(
        deviceId: 'dev-123',
        platform: 'android',
        appVersion: '1.3.2',
        buildNumber: '56',
        locale: 'ro_RO',
        timezone: 'EEST',
        timezoneOffsetMinutes: 180,
        osVersion: '16',
        deviceModel: 'Pixel 8',
        manufacturer: 'Google',
        isPhysicalDevice: true,
        fcmToken: 'tok-abc',
        extra: {'brand': 'google', 'sdk_int': 36},
      );

      expect(payload['device_id'], 'dev-123');
      expect(payload['platform'], 'android');
      expect(payload['os_version'], '16');
      expect(payload['device_model'], 'Pixel 8');
      expect(payload['manufacturer'], 'Google');
      expect(payload['is_physical_device'], true);
      expect(payload['app_version'], '1.3.2');
      expect(payload['build_number'], '56');
      expect(payload['locale'], 'ro_RO');
      expect(payload['timezone'], 'EEST');
      expect(payload['timezone_offset_minutes'], 180);
      expect(payload['fcm_token'], 'tok-abc');
      // extras are flattened into the payload
      expect(payload['brand'], 'google');
      expect(payload['sdk_int'], 36);
    });

    test('omits fcm_token when empty so the upsert never clears it', () {
      final payload = DeviceRegistrationService.buildPayload(
        deviceId: 'd',
        platform: 'ios',
        appVersion: '1',
        buildNumber: '1',
        locale: 'en_US',
        timezone: 'UTC',
        timezoneOffsetMinutes: 0,
        fcmToken: '',
      );

      expect(payload.containsKey('fcm_token'), isFalse);
    });

    test('omits unknown optional fields when null', () {
      final payload = DeviceRegistrationService.buildPayload(
        deviceId: 'd',
        platform: 'linux',
        appVersion: '1',
        buildNumber: '1',
        locale: 'en_US',
        timezone: 'UTC',
        timezoneOffsetMinutes: 0,
      );

      expect(payload.containsKey('device_model'), isFalse);
      expect(payload.containsKey('manufacturer'), isFalse);
      expect(payload.containsKey('is_physical_device'), isFalse);
    });
  });

  group('DeviceRegistrationService.register', () {
    test('is a no-op when the device id is empty (no network attempted)',
        () async {
      globals.deviceId = '';
      // Should complete without throwing and without an http client.
      await DeviceRegistrationService.instance.register();
    });
  });
}
