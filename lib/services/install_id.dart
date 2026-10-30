import 'dart:math';

/// A random identifier for this installation: a version 4 UUID in the
/// upper-case form of iOS's `identifierForVendor`.
///
/// For the desktop apps, which have no per-vendor id. A hardware id such as
/// the Mac's `IOPlatformUUID` (device_info_plus's `systemGUID`) never
/// changes and is the same for every app on the Mac, so it could follow the
/// user across apps, which Apple's privacy rules forbid. This one is kept in
/// the app's preferences (inside its sandbox container on macOS) and means
/// nothing outside the app.
String newInstallId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4: random.
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // The RFC 4122 variant.
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
