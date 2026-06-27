import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

/// Decides — via our own backend — whether this device should record its
/// screen (PostHog session replay).
///
/// The backend endpoint `GET /api/v1/session-recording/<device_id>/` returns
/// the decision based on a rollout percentage plus any manual per-device
/// override, so it can change without an app release.
///
/// To keep startup instant, [load] returns the value cached from the previous
/// launch and refreshes it in the background for the next launch. The very
/// first launch (before the backend has ever answered) defaults to disabled,
/// so no one is recorded until the backend opts them in.
class SessionRecordingService {
  static final SessionRecordingService _instance = SessionRecordingService._();
  static SessionRecordingService get instance => _instance;

  SessionRecordingService._();

  static const _kEnabledKey = 'session_recording_enabled';
  static const _kSampleRateKey = 'session_recording_sample_rate';

  /// Resolved settings for this launch (from cache), plus a background refresh.
  ///
  /// [sampleRate] is a 0.0–1.0 fraction passed straight to PostHog.
  Future<({bool enabled, double sampleRate})> load(
    SharedPreferences prefs,
    String deviceId,
  ) async {
    final enabled = prefs.getBool(_kEnabledKey) ?? false;
    final sampleRate = prefs.getDouble(_kSampleRateKey) ?? 1.0;

    // Refresh for next launch — fire-and-forget, never blocks startup.
    unawaited(_refresh(prefs, deviceId));

    return (enabled: enabled, sampleRate: sampleRate);
  }

  Future<void> _refresh(SharedPreferences prefs, String deviceId) async {
    if (deviceId.isEmpty) return;
    try {
      final uri = Uri.parse(
        '${CONSTANTS.SESSION_RECORDING_URL}/${Uri.encodeComponent(deviceId)}/',
      );
      final res = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final enabled = body['should_record'] == true;
      final sampleRate =
          ((body['sample_rate'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
      await prefs.setBool(_kEnabledKey, enabled);
      await prefs.setDouble(_kSampleRateKey, sampleRate);
    } catch (e) {
      // Offline / transient — keep the cached value for next launch.
      developer.log('Session recording refresh failed: $e');
    }
  }
}
