import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/globals.dart' as globals;
import 'package:radio_crestin/utils/api_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of a single private-stations fetch. Drives StationDataService's
/// merge and session-gate decisions.
enum PrivateFetchOutcome {
  /// HTTP 200 with a non-empty station list.
  /// [PrivateStationsResult.rawStations] carries the freshly-fetched raw maps.
  updated,

  /// HTTP 200 with an empty list — authoritative "this device has no private
  /// stations". The persisted cache was cleared and the session gate closed.
  emptyAuthoritative,

  /// HTTP 404 — endpoint not deployed yet. Last-known list is kept and the
  /// session gate is closed so we stop asking until the next launch/resume.
  notDeployed,

  /// Network error, 5xx, timeout, or missing device id. Last-known list is
  /// kept; the caller keeps retrying on the periodic cadence.
  transientFailure,

  /// Fetch skipped because the session gate is closed.
  skipped,
}

/// Result of [PrivateStationsService.fetch].
class PrivateStationsResult {
  const PrivateStationsResult(this.outcome, {this.rawStations});

  final PrivateFetchOutcome outcome;

  /// Raw station maps (same shape as the public `/stations` payload), present
  /// only for [PrivateFetchOutcome.updated].
  final List<Map<String, dynamic>>? rawStations;
}

/// Fetches and persists the device-allowlisted ("private") station list.
///
/// Owns the fetch policy state machine and the SharedPreferences cache. Turning
/// the raw station JSON into `Station`s stays in `StationDataService`, which
/// already holds the typename injection and reviews-stats sideload it must
/// reuse — this service deliberately does no GraphQL parsing so it stays a
/// small, easily-testable HTTP + policy unit.
class PrivateStationsService {
  PrivateStationsService({
    http.Client? httpClient,
    SharedPreferences? prefs,
    String Function()? deviceIdProvider,
  })  : _httpClient = httpClient ?? http.Client(),
        _injectedPrefs = prefs,
        _deviceIdProvider = deviceIdProvider ?? (() => globals.deviceId);

  /// SharedPreferences key mirroring the public `cached_stations_data` pattern.
  static const cacheKey = 'cached_private_stations_data';

  static const _timeout = Duration(seconds: 8);

  final http.Client _httpClient;
  final SharedPreferences? _injectedPrefs;
  final String Function() _deviceIdProvider;

  /// Closed after an authoritative-empty or not-deployed response so we stop
  /// hammering a device that has no private stations (or an endpoint that isn't
  /// live). Reopened on app launch (a fresh instance) or resume.
  bool _sessionGateClosed = false;
  bool get isSessionGateClosed => _sessionGateClosed;

  SharedPreferences get _prefs =>
      _injectedPrefs ?? GetIt.instance<SharedPreferences>();

  void _log(String message) => debugPrint('PrivateStationsService: $message');

  /// Reopens the session gate so the next [fetch] runs. Called on app resume;
  /// a fresh launch starts open anyway.
  void reopenSessionGate() => _sessionGateClosed = false;

  /// Loads the persisted raw private station maps for instant bootstrap before
  /// the network responds. Returns null when nothing is cached or the cache is
  /// unreadable.
  List<Map<String, dynamic>>? loadCachedRaw() {
    try {
      final cached = _prefs.getString(cacheKey);
      if (cached == null) return null;
      final decoded = json.decode(cached);
      final list =
          decoded is Map<String, dynamic> ? decoded['stations'] : decoded;
      if (list is! List) return null;
      final result = list.whereType<Map<String, dynamic>>().toList();
      return result.isEmpty ? null : result;
    } catch (e) {
      _log('cache read failed: $e');
      return null;
    }
  }

  /// Performs one fetch and applies the persistence + session-gate policy.
  /// Never throws — every failure maps to an outcome.
  Future<PrivateStationsResult> fetch() async {
    if (_sessionGateClosed) {
      return const PrivateStationsResult(PrivateFetchOutcome.skipped);
    }

    final deviceId = _deviceIdProvider().trim();
    if (deviceId.isEmpty) {
      // Device id not resolved yet — treat as transient so the periodic tick
      // retries once it's available. Never close the gate on this.
      _log('device id not available yet; will retry');
      return const PrivateStationsResult(PrivateFetchOutcome.transientFailure);
    }

    final uri = Uri.parse(CONSTANTS.PRIVATE_STATIONS_URL).replace(
      queryParameters: <String, String>{
        'device_id': deviceId,
        'timestamp': getRoundedTimestamp60s().toString(),
      },
    );

    try {
      final response = await _httpClient.get(uri).timeout(_timeout);

      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        final data = body is Map<String, dynamic> ? body['data'] : null;
        final stations = data is Map<String, dynamic> ? data['stations'] : null;
        final raw = (stations is List ? stations : const [])
            .whereType<Map<String, dynamic>>()
            .toList();

        if (raw.isEmpty) {
          await _clearCache();
          _sessionGateClosed = true;
          _log('empty (authoritative) → cache cleared, gate closed');
          return const PrivateStationsResult(
              PrivateFetchOutcome.emptyAuthoritative);
        }

        await _persist(raw);
        _log('updated → ${raw.length} private stations');
        return PrivateStationsResult(PrivateFetchOutcome.updated,
            rawStations: raw);
      }

      if (response.statusCode == 404) {
        _sessionGateClosed = true;
        _log('404 (not deployed) → keep last known, gate closed');
        return const PrivateStationsResult(PrivateFetchOutcome.notDeployed);
      }

      _log('HTTP ${response.statusCode} → transient, will retry');
      return const PrivateStationsResult(PrivateFetchOutcome.transientFailure);
    } catch (e) {
      _log('fetch error → transient, will retry: $e');
      return const PrivateStationsResult(PrivateFetchOutcome.transientFailure);
    }
  }

  Future<void> _persist(List<Map<String, dynamic>> raw) async {
    try {
      await _prefs.setString(cacheKey, json.encode({'stations': raw}));
    } catch (e) {
      _log('cache write failed: $e');
    }
  }

  Future<void> _clearCache() async {
    try {
      await _prefs.remove(cacheKey);
    } catch (e) {
      _log('cache clear failed: $e');
    }
  }
}
