import 'package:shared_preferences/shared_preferences.dart';

/// Reports each installation of the app once, after the device is
/// identified.
///
/// PostHog's own `Application Installed` goes out before
/// `AnalyticsService.identify`, under an anonymous ID that identify's
/// `reset()` drops, so it never reaches the device's person. This report is
/// keyed on the OS install time instead: a reinstall has a new install time
/// on the same device ID, so it is reported again.
class InstallReporter {
  static const reportedKey = 'reported_install_time_ms';

  /// Calls [report] with [installTime] unless that install was reported.
  ///
  /// [knownDevice] means a device ID was stored before this launch: an
  /// update from a version that didn't report installs. Its install time is
  /// remembered without a report, since that install happened long ago.
  /// Returns whether [report] was called.
  static Future<bool> reportOnce({
    required SharedPreferences prefs,
    required DateTime? installTime,
    required bool knownDevice,
    required void Function(DateTime installTime) report,
  }) async {
    if (installTime == null) return false;
    final installMs = installTime.millisecondsSinceEpoch;
    final reportedMs = prefs.getInt(reportedKey);
    if (reportedMs == installMs) return false;
    await prefs.setInt(reportedKey, installMs);
    if (reportedMs == null && knownDevice) return false;
    report(installTime);
    return true;
  }
}
