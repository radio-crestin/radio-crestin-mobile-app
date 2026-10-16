import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/app_start_log.dart';
import 'package:radio_crestin/services/remote_debug_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 10, 16, 12);

  Future<Map<String, Object>> attributesWith(
    Map<String, Object> prefsValues,
  ) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    await RemoteDebugController.instance.loadCache(prefs);
    return AppStartLog.attributes(
      prefs: prefs,
      appVersion: '1.5.1',
      buildNumber: '91',
      device: const {'os_version': '26.0', 'device_model': 'iPhone14,5'},
      locale: 'ro_RO',
      now: now,
    );
  }

  setUp(() {
    SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
    SeekModeManager.changeUnstableConnection(false);
  });

  test('names the build, the phone, the locale and the time zone', () async {
    final attributes = await attributesWith({});

    expect(attributes['app_version'], '1.5.1');
    expect(attributes['build_number'], '91');
    expect(attributes['build_mode'], AnalyticsService.buildMode);
    expect(attributes['platform'], Platform.operatingSystem);
    expect(attributes['os_version'], '26.0');
    expect(attributes['device_model'], 'iPhone14,5');
    expect(attributes['tv'], isFalse);
    expect(attributes['locale'], 'ro_RO');
    expect(attributes['timezone'], now.timeZoneName);
    expect(attributes['timezone_offset_minutes'], now.timeZoneOffset.inMinutes);
  });

  test('lists the settings that shape playback', () async {
    SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
    SeekModeManager.changeUnstableConnection(true);

    final attributes = await attributesWith({
      '_autoStartStation': false,
      'developer_mode_enabled': true,
    });

    expect(attributes['seek_mode'], 'fiveMinutes');
    expect(attributes['unstable_connection'], isTrue);
    expect(attributes['auto_start'], isFalse);
    expect(attributes['notifications'], isTrue);
    expect(attributes['developer_mode'], isTrue);
    expect(attributes['hls_watchdog'], isTrue);
  });

  test('details the remote debug flag only while it is on', () async {
    final off = await attributesWith({});
    expect(off['remote_debug'], isFalse);
    expect(off.containsKey('remote_verbose_logs'), isFalse);

    final on = await attributesWith({
      'remote_debug_enabled': true,
      'remote_debug_verbose_logs': true,
      'remote_debug_upload_logs': false,
    });
    expect(on['remote_debug'], isTrue);
    expect(on['remote_verbose_logs'], isTrue);
    expect(on['remote_upload_logs'], isFalse);
  });

  test('never carries the device id', () async {
    final attributes = await attributesWith({'device_id': 'secret-id'});

    expect(attributes.values, isNot(contains('secret-id')));
    expect(attributes.containsKey('device_id'), isFalse);
  });
}
