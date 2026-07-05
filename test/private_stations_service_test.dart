import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/private_stations_service.dart';

import 'helpers/station_factory.dart';

/// Policy state-machine tests for [PrivateStationsService]:
///   empty        → disable (close gate) + clear cache
///   404          → disable (close gate) + keep cache
///   failure/5xx  → keep cache + keep retrying (gate stays open)
///   non-empty    → persist raw + return stations (gate stays open → polls)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  String stationsBody(List<Map<String, dynamic>> stations) =>
      json.encode({
        'data': {'stations': stations}
      });

  PrivateStationsService service(
    MockClient client, {
    String deviceId = 'device-1',
  }) =>
      PrivateStationsService(
        httpClient: client,
        prefs: prefs,
        deviceIdProvider: () => deviceId,
      );

  group('Non-empty (updated)', () {
    test('returns the raw stations and persists them to prefs', () async {
      final station = StationFactory.createRawStationJson(
        id: 42,
        slug: 'private-one',
        title: 'Private One',
      );
      final client = MockClient(
        (_) async => http.Response(stationsBody([station]), 200),
      );

      final result = await service(client).fetch();

      expect(result.outcome, PrivateFetchOutcome.updated);
      expect(result.rawStations, hasLength(1));
      expect(result.rawStations!.first['id'], 42);

      // Persisted for instant bootstrap next launch.
      final cached = prefs.getString(PrivateStationsService.cacheKey);
      expect(cached, isNotNull);
      expect(cached, contains('private-one'));
    });

    test('gate stays open so the periodic tick keeps polling', () async {
      final station = StationFactory.createRawStationJson(
        id: 1,
        slug: 's',
        title: 'S',
      );
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(stationsBody([station]), 200);
      });
      final svc = service(client);

      await svc.fetch();
      await svc.fetch();

      expect(svc.isSessionGateClosed, isFalse);
      expect(calls, 2, reason: 'both fetches hit the network');
    });
  });

  group('Empty (authoritative)', () {
    test('closes the gate and clears any persisted cache', () async {
      await prefs.setString(PrivateStationsService.cacheKey, '{"stations":[]}');
      final client = MockClient(
        (_) async => http.Response(stationsBody([]), 200),
      );
      final svc = service(client);

      final result = await svc.fetch();

      expect(result.outcome, PrivateFetchOutcome.emptyAuthoritative);
      expect(result.rawStations, isNull);
      expect(svc.isSessionGateClosed, isTrue);
      expect(prefs.getString(PrivateStationsService.cacheKey), isNull);
    });

    test('subsequent fetch is skipped without a network call', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(stationsBody([]), 200);
      });
      final svc = service(client);

      await svc.fetch();
      final second = await svc.fetch();

      expect(second.outcome, PrivateFetchOutcome.skipped);
      expect(calls, 1, reason: 'gate closed → no second request');
    });
  });

  group('404 (not deployed)', () {
    test('closes the gate but keeps the last-known cache', () async {
      await prefs.setString(
          PrivateStationsService.cacheKey, '{"stations":[{"id":9}]}');
      final client = MockClient((_) async => http.Response('not found', 404));
      final svc = service(client);

      final result = await svc.fetch();

      expect(result.outcome, PrivateFetchOutcome.notDeployed);
      expect(svc.isSessionGateClosed, isTrue);
      expect(prefs.getString(PrivateStationsService.cacheKey), isNotNull,
          reason: '404 must not wipe the cache');
    });

    test('stops asking for the rest of the session', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('not found', 404);
      });
      final svc = service(client);

      await svc.fetch();
      await svc.fetch();

      expect(calls, 1);
    });
  });

  group('Transient failure', () {
    test('5xx keeps the gate open and keeps retrying', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('boom', 503);
      });
      final svc = service(client);

      final first = await svc.fetch();
      final second = await svc.fetch();

      expect(first.outcome, PrivateFetchOutcome.transientFailure);
      expect(second.outcome, PrivateFetchOutcome.transientFailure);
      expect(svc.isSessionGateClosed, isFalse);
      expect(calls, 2, reason: 'retries every tick until success/empty/404');
    });

    test('network exception maps to transientFailure', () async {
      final client = MockClient((_) async => throw Exception('offline'));
      final svc = service(client);

      final result = await svc.fetch();

      expect(result.outcome, PrivateFetchOutcome.transientFailure);
      expect(svc.isSessionGateClosed, isFalse);
    });

    test('empty device id is transient and never hits the network', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(stationsBody([]), 200);
      });
      final svc = service(client, deviceId: '');

      final result = await svc.fetch();

      expect(result.outcome, PrivateFetchOutcome.transientFailure);
      expect(svc.isSessionGateClosed, isFalse);
      expect(calls, 0);
    });
  });

  group('Session gate', () {
    test('reopenSessionGate re-enables fetching after a close', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('not found', 404);
      });
      final svc = service(client);

      await svc.fetch(); // closes gate
      svc.reopenSessionGate();
      final again = await svc.fetch();

      expect(again.outcome, PrivateFetchOutcome.notDeployed);
      expect(calls, 2, reason: 'reopened gate lets the next fetch through');
    });
  });

  group('Request shape', () {
    test('sends device_id and a 60s-floored timestamp', () async {
      late Uri captured;
      final client = MockClient((request) async {
        captured = request.url;
        return http.Response(stationsBody([]), 200);
      });

      await service(client, deviceId: 'abc-123').fetch();

      expect(captured.queryParameters['device_id'], 'abc-123');
      final ts = int.parse(captured.queryParameters['timestamp']!);
      expect(ts % 60, 0, reason: 'timestamp floored to a 60s window');
    });
  });

  group('loadCachedRaw', () {
    test('returns persisted stations for instant bootstrap', () async {
      final station = StationFactory.createRawStationJson(
        id: 7,
        slug: 'cached',
        title: 'Cached',
      );
      await prefs.setString(PrivateStationsService.cacheKey,
          json.encode({'stations': [station]}));

      final loaded = PrivateStationsService(prefs: prefs).loadCachedRaw();

      expect(loaded, hasLength(1));
      expect(loaded!.first['slug'], 'cached');
    });

    test('returns null when nothing is cached', () {
      final loaded = PrivateStationsService(prefs: prefs).loadCachedRaw();
      expect(loaded, isNull);
    });

    test('returns null for an empty cached list', () async {
      await prefs.setString(
          PrivateStationsService.cacheKey, '{"stations":[]}');
      final loaded = PrivateStationsService(prefs: prefs).loadCachedRaw();
      expect(loaded, isNull);
    });
  });
}
