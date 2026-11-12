import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'analytics_service.dart';

/// An ANR Android recorded for this app: its main thread was blocked long
/// enough (5 s for a tap or key) for the system to report it.
class AndroidAnr implements Exception {
  AndroidAnr(this.reason);

  /// What Android said, without the numbers that differ each time, so that
  /// the same kind of ANR groups into one Error Tracking issue.
  final String reason;

  @override
  String toString() => 'ANR: $reason';
}

/// Reports to PostHog the ANRs Android recorded since the last launch, with
/// the main thread's stack (`AnrReports.kt`).
///
/// Since Flutter 3.29 the app's Dart code runs on Android's main thread, so
/// any long synchronous Dart work can freeze the app into an ANR. Play
/// Console shows them days later; this shows them at the next launch.
abstract final class AnrReporter {
  static const _channel = MethodChannel('com.radiocrestin.app');

  /// Never throws: a report that can't be read is skipped.
  static Future<void> reportRecorded() async {
    if (!Platform.isAndroid) return;
    try {
      final anrs = await _channel.invokeListMethod<Map>('takeAnrReports');
      for (final anr in anrs ?? const <Map>[]) {
        _report(anr);
      }
    } catch (e) {
      developer.log('AnrReporter: could not read the recorded ANRs: $e');
    }
  }

  static void _report(Map anr) {
    final description = anr['description'] as String? ?? 'unknown';
    final timestamp = anr['timestamp'] as int?;
    AnalyticsService.instance.captureException(
      AndroidAnr(withoutNumbers(description)),
      null,
      context: 'android_anr',
      properties: {
        'anr_description': description,
        'anr_main_thread': anr['main_thread'],
        'anr_importance': anr['importance'],
        if (timestamp != null)
          'anr_at': DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true)
              .toIso8601String(),
      },
    );
  }

  /// [description] with its pids, durations and addresses replaced by `#`.
  static String withoutNumbers(String description) =>
      description.replaceAll(RegExp(r'\b(0x)?[0-9a-f]*\d[0-9a-f]*\b'), '#');
}
