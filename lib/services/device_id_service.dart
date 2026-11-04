import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'install_id.dart';

/// The platform this device runs, as far as its ID is concerned.
enum DeviceIdPlatform { android, ios, other }

/// Finds this device's persistent ID, kept across reinstalls where the
/// platform allows it.
///
/// - Android: `ANDROID_ID`, unique per phone, user and signing key, and kept
///   across reinstalls until a factory reset. Versions before 1.5.1 stored
///   `Build.ID` instead, the firmware's build label that every phone on that
///   firmware shares; such an ID is replaced.
/// - iOS: kept in the Keychain, which a reinstall finds again. A new ID is
///   the vendor ID, as before, so existing users keep the ID they had.
/// - Desktop: a random ID kept in the app's preferences (see
///   [newInstallId]).
///
/// The ID is also saved in preferences under [prefsKey], where the share
/// link code reads it.
class DeviceIdService {
  DeviceIdService(
    this._prefs, {
    DeviceIdPlatform? platform,
    Future<String?> Function()? readAndroidId,
    Future<String?> Function()? readVendorId,
    Future<String?> Function()? readKeychain,
    Future<void> Function(String id)? writeKeychain,
  })  : _platform = platform ?? _currentPlatform(),
        _readAndroidId = readAndroidId ?? const AndroidId().getId,
        _readVendorId = readVendorId ?? _vendorId,
        _readKeychain = readKeychain ?? _keychainRead,
        _writeKeychain = writeKeychain ?? _keychainWrite;

  static const prefsKey = 'device_id';
  static const _keychain = MethodChannel('com.radiocrestin.device_id');

  final SharedPreferences _prefs;
  final DeviceIdPlatform _platform;
  final Future<String?> Function() _readAndroidId;
  final Future<String?> Function() _readVendorId;
  final Future<String?> Function() _readKeychain;
  final Future<void> Function(String id) _writeKeychain;

  /// The device's ID, created and saved on the first launch.
  Future<String> resolve() async {
    final id = await _existingId() ?? await _newId();
    if (_prefs.getString(prefsKey) != id) {
      await _prefs.setString(prefsKey, id);
    }
    return id;
  }

  Future<String?> _existingId() => switch (_platform) {
        DeviceIdPlatform.android => _androidExistingId(),
        DeviceIdPlatform.ios => _iosExistingId(),
        DeviceIdPlatform.other => Future.value(_storedId()),
      };

  /// The live `ANDROID_ID` wins over the stored one, which Android's backup
  /// may have copied from another phone. The stored one only stands in
  /// when the live one can't be read, and never when it is a `Build.ID`.
  Future<String?> _androidExistingId() async {
    final androidId = await _safely(_readAndroidId);
    if (isAndroidId(androidId)) return androidId;
    final stored = _storedId();
    return isAndroidId(stored) || isInstallId(stored) ? stored : null;
  }

  /// The Keychain keeps the ID through a reinstall; preferences hold it for
  /// users who updated from a version without the Keychain copy.
  Future<String?> _iosExistingId() async {
    final kept = _nonEmpty(await _safely(_readKeychain));
    if (kept != null) return kept;
    final stored = _storedId();
    if (stored != null) await _keep(stored);
    return stored;
  }

  Future<String> _newId() async {
    if (_platform != DeviceIdPlatform.ios) return newInstallId();
    final id = _nonEmpty(await _safely(_readVendorId)) ?? newInstallId();
    await _keep(id);
    return id;
  }

  Future<void> _keep(String id) => _safely(() async {
        await _writeKeychain(id);
        return null;
      });

  String? _storedId() => _nonEmpty(_prefs.getString(prefsKey));

  /// Whether [id] looks like an `ANDROID_ID`: 64 bits in hex.
  static bool isAndroidId(String? id) =>
      id != null && RegExp(r'^[0-9a-fA-F]{8,16}$').hasMatch(id);

  /// Whether [id] is one made by [newInstallId].
  static bool isInstallId(String? id) =>
      id != null &&
      RegExp(r'^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$').hasMatch(id);

  static String? _nonEmpty(String? id) =>
      id == null || id.trim().isEmpty ? null : id;

  static Future<String?> _safely(Future<String?> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }

  static DeviceIdPlatform _currentPlatform() {
    if (Platform.isAndroid) return DeviceIdPlatform.android;
    if (Platform.isIOS) return DeviceIdPlatform.ios;
    return DeviceIdPlatform.other;
  }

  static Future<String?> _vendorId() async =>
      (await DeviceInfoPlugin().iosInfo).identifierForVendor;

  static Future<String?> _keychainRead() =>
      _keychain.invokeMethod<String>('read');

  static Future<void> _keychainWrite(String id) =>
      _keychain.invokeMethod<bool>('write', id);
}
