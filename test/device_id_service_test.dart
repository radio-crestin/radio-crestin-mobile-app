import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/device_id_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _androidId = '3f9a1c0d5e7b2a46';
const _buildId = 'RSR1.240422.006';
const _vendorId = '6CF1BDB4-83E6-4345-93F1-B17A8D866ACC';

/// A Keychain stand-in that remembers what was written.
class _FakeKeychain {
  _FakeKeychain([this.value]);
  String? value;
  Future<String?> read() async => value;
  Future<void> write(String id) async => value = id;
}

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

DeviceIdService _android(SharedPreferences prefs, String? androidId) =>
    DeviceIdService(
      prefs,
      platform: DeviceIdPlatform.android,
      readAndroidId: () async => androidId,
    );

DeviceIdService _ios(SharedPreferences prefs, _FakeKeychain keychain) =>
    DeviceIdService(
      prefs,
      platform: DeviceIdPlatform.ios,
      readVendorId: () async => _vendorId,
      readKeychain: keychain.read,
      writeKeychain: keychain.write,
    );

void main() {
  group('Android', () {
    test('a fresh install gets ANDROID_ID', () async {
      final prefs = await _prefs();
      expect(await _android(prefs, _androidId).resolve(), _androidId);
      expect(prefs.getString(DeviceIdService.prefsKey), _androidId);
    });

    test('a stored Build.ID is replaced by ANDROID_ID', () async {
      final prefs = await _prefs({DeviceIdService.prefsKey: _buildId});
      expect(await _android(prefs, _androidId).resolve(), _androidId);
      expect(prefs.getString(DeviceIdService.prefsKey), _androidId);
    });

    test('ANDROID_ID wins over an ID restored from another phone', () async {
      final prefs = await _prefs({DeviceIdService.prefsKey: 'aaaabbbbccccdddd'});
      expect(await _android(prefs, _androidId).resolve(), _androidId);
    });

    test('without ANDROID_ID, a stored per-device ID is kept', () async {
      final prefs = await _prefs({DeviceIdService.prefsKey: _androidId});
      expect(await _android(prefs, null).resolve(), _androidId);
    });

    test('without ANDROID_ID, a Build.ID becomes a random ID', () async {
      final prefs = await _prefs({DeviceIdService.prefsKey: _buildId});
      final id = await _android(prefs, null).resolve();
      expect(DeviceIdService.isInstallId(id), isTrue);
    });

    test('a failing ANDROID_ID read does not throw', () async {
      final prefs = await _prefs();
      final service = DeviceIdService(
        prefs,
        platform: DeviceIdPlatform.android,
        readAndroidId: () async => throw Exception('no plugin'),
      );
      expect(DeviceIdService.isInstallId(await service.resolve()), isTrue);
    });
  });

  group('iOS', () {
    test('a fresh install gets the vendor ID, kept in the Keychain', () async {
      final prefs = await _prefs();
      final keychain = _FakeKeychain();
      expect(await _ios(prefs, keychain).resolve(), _vendorId);
      expect(keychain.value, _vendorId);
    });

    test('a reinstall finds its old ID in the Keychain', () async {
      final prefs = await _prefs();
      final keychain = _FakeKeychain('OLD-ID');
      expect(await _ios(prefs, keychain).resolve(), 'OLD-ID');
      expect(prefs.getString(DeviceIdService.prefsKey), 'OLD-ID');
    });

    test('an update copies the stored ID into the Keychain', () async {
      final prefs = await _prefs({DeviceIdService.prefsKey: 'STORED-ID'});
      final keychain = _FakeKeychain();
      expect(await _ios(prefs, keychain).resolve(), 'STORED-ID');
      expect(keychain.value, 'STORED-ID');
    });
  });

  test('desktop keeps its stored ID', () async {
    final prefs = await _prefs({DeviceIdService.prefsKey: 'DESKTOP-ID'});
    final service = DeviceIdService(prefs, platform: DeviceIdPlatform.other);
    expect(await service.resolve(), 'DESKTOP-ID');
  });

  test('isAndroidId rejects firmware build labels', () {
    expect(DeviceIdService.isAndroidId(_androidId), isTrue);
    expect(DeviceIdService.isAndroidId(_buildId), isFalse);
    expect(DeviceIdService.isAndroidId('QPWS30.61-21-18-7'), isFalse);
    expect(DeviceIdService.isAndroidId(null), isFalse);
  });
}
