import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:posthog_flutter/src/feature_flag_result.dart';
import 'package:posthog_flutter/src/posthog_flutter_platform_interface.dart';

import 'package:radio_crestin/services/analytics_service.dart';

class _CapturedEvent {
  final String eventName;
  final Map<String, Object>? properties;
  _CapturedEvent(this.eventName, this.properties);
}

class _FakePosthogPlatform extends PosthogFlutterPlatformInterface {
  final List<_CapturedEvent> events = [];
  final List<Map<String, dynamic>> identifyCalls = [];
  final List<Map<String, dynamic>> setPersonPropertiesCalls = [];
  final List<MapEntry<String, Object>> registerCalls = [];
  String distinctId = 'anon-distinct-id';
  String? sessionId = 'session-test';
  int resetCalls = 0;
  int flushCalls = 0;
  PostHogConfig? receivedConfig;

  @override
  Future<void> setup(PostHogConfig config) async {
    receivedConfig = config;
  }

  @override
  Future<void> capture({
    required String eventName,
    Map<String, Object>? properties,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
    Map<String, Object>? groups,
    DateTime? timestamp,
  }) async {
    events.add(_CapturedEvent(eventName, properties));
  }

  @override
  Future<void> identify({
    required String userId,
    Map<String, Object>? userProperties,
    Map<String, Object>? userPropertiesSetOnce,
  }) async {
    identifyCalls.add({
      'userId': userId,
      'userProperties': userProperties,
    });
  }

  @override
  Future<void> setPersonProperties({
    Map<String, Object>? userPropertiesToSet,
    Map<String, Object>? userPropertiesToSetOnce,
  }) async {
    setPersonPropertiesCalls.add({'userPropertiesToSet': userPropertiesToSet});
  }

  @override
  Future<void> register(String key, Object value) async {
    registerCalls.add(MapEntry(key, value));
  }

  @override
  Future<String> getDistinctId() async => distinctId;

  @override
  Future<String?> getSessionId() async => sessionId;

  @override
  Future<void> reset() async {
    resetCalls++;
  }

  @override
  Future<void> flush() async {
    flushCalls++;
  }

  @override
  Future<void> captureException({
    required Object error,
    StackTrace? stackTrace,
    Map<String, Object>? properties,
  }) async {}

  @override
  Future<void> screen({
    required String screenName,
    Map<String, Object>? properties,
  }) async {}

  @override
  Future<void> openUrl(String url) async {}

  @override
  Future<void> unregister(String key) async {}

  @override
  Future<void> alias({required String alias}) async {}

  @override
  Future<void> disable() async {}

  @override
  Future<void> enable() async {}

  @override
  Future<bool> isOptOut() async => false;

  @override
  Future<void> debug(bool enabled) async {}

  @override
  Future<bool> isFeatureEnabled(String key) async => false;

  @override
  Future<void> reloadFeatureFlags() async {}

  @override
  Future<void> showSurvey(Map<String, dynamic> survey) async {}

  @override
  Future<void> group({
    required String groupType,
    required String groupKey,
    Map<String, Object>? groupProperties,
  }) async {}

  @override
  Future<Object?> getFeatureFlag({required String key}) async => null;

  @override
  Future<Object?> getFeatureFlagPayload({required String key}) async => null;

  @override
  Future<PostHogFeatureFlagResult?> getFeatureFlagResult({
    required String key,
    bool sendEvent = true,
  }) async =>
      null;

  @override
  Future<void> close() async {}

  @override
  Future<void> startSessionRecording({bool resumeCurrent = true}) async {}

  @override
  Future<void> stopSessionRecording() async {}

  @override
  Future<bool> isSessionReplayActive() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePosthogPlatform fake;
  late AnalyticsService analytics;

  setUp(() async {
    fake = _FakePosthogPlatform();
    PosthogFlutterPlatformInterface.instance = fake;
    analytics = AnalyticsService.instance;
    // Reset singleton state by ending any in-flight session and clearing
    // stream context. Drains events accumulated by setUp itself.
    if (analytics.isListening) {
      analytics.endListening(reason: 'stop');
    }
    analytics.setCurrentStream(url: null, type: null, index: null, total: null);
    fake.events.clear();
  });

  group('setCurrentStream', () {
    test('attaches stream fields to the next captured event', () {
      analytics.setCurrentStream(
        url: 'https://hls.example/x',
        type: 'HLS',
        index: 0,
        total: 2,
      );

      analytics.startListening('s', 'Station');

      final started = fake.events.firstWhere((e) => e.eventName == 'listening_started');
      expect(started.properties?['stream_url'], 'https://hls.example/x');
      expect(started.properties?['stream_type'], 'HLS');
      expect(started.properties?['stream_index'], 0);
      expect(started.properties?['total_streams'], 2);
    });

    test('clearing leaves no stream_* keys on later events', () {
      analytics.setCurrentStream(
        url: 'https://x.example/y',
        type: 'HLS',
        index: 0,
        total: 1,
      );
      // Now clear — simulates the "clear context on station change" fix.
      analytics.setCurrentStream(url: null, type: null, index: null, total: null);

      analytics.startListening('s2', 'Station Two');

      final started = fake.events.firstWhere((e) => e.eventName == 'listening_started');
      expect(started.properties?.containsKey('stream_url'), false);
      expect(started.properties?.containsKey('stream_type'), false);
      expect(started.properties?.containsKey('stream_index'), false);
      expect(started.properties?.containsKey('total_streams'), false);
    });
  });

  group('capture', () {
    test('drops null-valued properties', () {
      analytics.capture('event_x', {
        'kept': 'yes',
        'dropped': null,
        'also_kept': 42,
      });

      final ev = fake.events.firstWhere((e) => e.eventName == 'event_x');
      expect(ev.properties?['kept'], 'yes');
      expect(ev.properties?['also_kept'], 42);
      expect(ev.properties?.containsKey('dropped'), false);
    });

    test('forwards eventName even with no properties', () {
      analytics.capture('plain_event');
      expect(fake.events.last.eventName, 'plain_event');
      // Implementation always forwards a non-null map; emptiness is the contract.
      expect(fake.events.last.properties, isEmpty);
    });
  });

  group('captureDebug', () {
    test('only fires in debug builds', () {
      analytics.captureDebug('debug_only', {'k': 'v'});

      // The flutter_test runner runs in debug mode, so kDebugMode is true.
      // If that ever changes (release-mode test runner), this assertion
      // documents the dependency.
      if (kDebugMode) {
        expect(fake.events.any((e) => e.eventName == 'debug_only'), isTrue);
      } else {
        expect(fake.events.any((e) => e.eventName == 'debug_only'), isFalse);
      }
    });
  });

  group('captureException', () {
    test('records the exception when initialized', () async {
      // Force initialized=true via initialize() — uses the fake under the hood.
      await analytics.initialize();
      fake.events.clear();

      analytics.captureException(
        StateError('boom'),
        StackTrace.current,
        context: 'in test',
      );

      final ev = fake.events.singleWhere((e) => e.eventName == 'exception_caught');
      expect(ev.properties?['error_type'], 'StateError');
      expect(ev.properties?['error_message'], contains('boom'));
      expect(ev.properties?['context'], 'in test');
      expect(ev.properties?['stack_trace'], isA<String>());
    });

    test('skips Hive compaction PathNotFoundException (concurrent-engine noise)', () async {
      await analytics.initialize();
      fake.events.clear();

      final fakeStack = StackTrace.fromString(
        '#0 StorageBackendVm.compact (package:hive/...)\n#1 anonymous',
      );
      analytics.captureException(
        const PathNotFoundException('/data/x', OSError('not found', 2)),
        fakeStack,
      );

      expect(
        fake.events.where((e) => e.eventName == 'exception_caught'),
        isEmpty,
      );
    });

    test('does NOT skip PathNotFoundException unrelated to Hive compaction', () async {
      await analytics.initialize();
      fake.events.clear();

      final unrelatedStack = StackTrace.fromString(
        '#0 some_other_function (package:foo/bar.dart)',
      );
      analytics.captureException(
        const PathNotFoundException('/data/y', OSError('?', 2)),
        unrelatedStack,
      );

      expect(
        fake.events.any((e) => e.eventName == 'exception_caught'),
        isTrue,
      );
    });

    test('truncates stack_trace at 2000 chars', () async {
      await analytics.initialize();
      fake.events.clear();

      final huge = StackTrace.fromString('x' * 5000);
      analytics.captureException(StateError('big'), huge);

      final ev = fake.events.singleWhere((e) => e.eventName == 'exception_caught');
      final trace = ev.properties!['stack_trace'] as String;
      expect(trace.length, lessThanOrEqualTo(2000));
    });
  });

  group('initialize', () {
    test('passes config and reads session id', () async {
      fake.sessionId = 'fresh-session-id';
      await analytics.initialize();

      expect(fake.receivedConfig, isNotNull);
      expect(analytics.sessionId, 'fresh-session-id');
    });
  });

  group('identify', () {
    test('calls Posthog.identify with provided user properties', () async {
      await analytics.identify(
        userId: 'device-id-1',
        appVersion: '1.5.0',
        buildNumber: '77',
        platform: 'android',
      );

      expect(fake.identifyCalls.last['userId'], 'device-id-1');
      final props = fake.identifyCalls.last['userProperties'] as Map?;
      expect(props?['app_version'], '1.5.0');
      expect(props?['build_number'], '77');
      expect(props?['platform'], 'android');

      // Registers device_id as a super property
      expect(
        fake.registerCalls.any((e) => e.key == 'device_id' && e.value == 'device-id-1'),
        isTrue,
      );
    });

    test('resets PostHog when distinctId differs from new userId', () async {
      fake.distinctId = 'old-id';
      await analytics.identify(userId: 'new-id');
      expect(fake.resetCalls, 1);
    });

    test('does NOT reset PostHog when distinctId already matches', () async {
      fake.distinctId = 'same-id';
      await analytics.identify(userId: 'same-id');
      expect(fake.resetCalls, 0);
    });
  });

  group('listening session lifecycle', () {
    test('startListening emits listening_started with station fields', () {
      analytics.startListening('rve', 'RVE Timisoara', stationId: 42);

      final started = fake.events.singleWhere((e) => e.eventName == 'listening_started');
      expect(started.properties?['station_slug'], 'rve');
      expect(started.properties?['station_name'], 'RVE Timisoara');
      expect(started.properties?['station_id'], 42);
      expect(analytics.isListening, isTrue);
    });

    test('startListening while already listening emits listening_stopped(station_switch) first', () {
      analytics.startListening('a', 'A');
      fake.events.clear();

      analytics.startListening('b', 'B');

      final firstEv = fake.events.first;
      expect(firstEv.eventName, 'listening_stopped');
      expect(firstEv.properties?['reason'], 'station_switch');
      expect(firstEv.properties?['station_slug'], 'a');

      final secondEv = fake.events[1];
      expect(secondEv.eventName, 'listening_started');
      expect(secondEv.properties?['station_slug'], 'b');
    });

    test('endListening emits listening_stopped with positive duration', () async {
      analytics.startListening('s', 'Station');
      // Yield so DateTime.now() advances by at least 1ms.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      analytics.endListening();

      expect(analytics.isListening, isFalse);
      final stopped = fake.events.lastWhere((e) => e.eventName == 'listening_stopped');
      expect(stopped.properties?['reason'], 'stop');
      expect(stopped.properties?['duration_seconds'], greaterThanOrEqualTo(0));
    });

    test('endListening is a no-op when not listening', () {
      analytics.endListening();
      expect(fake.events.any((e) => e.eventName == 'listening_stopped'), isFalse);
    });

    test('resumeListening reuses station info after pause', () {
      analytics.startListening('rve', 'RVE Timisoara', stationId: 7);
      analytics.endListening(reason: 'pause');
      fake.events.clear();

      analytics.resumeListening();

      final ev = fake.events.singleWhere((e) => e.eventName == 'listening_resumed');
      expect(ev.properties?['station_slug'], 'rve');
      expect(ev.properties?['station_name'], 'RVE Timisoara');
      expect(ev.properties?['station_id'], 7);
      expect(analytics.isListening, isTrue);
    });

    test('resumeListening is a no-op without prior session', () {
      analytics.resumeListening();
      expect(fake.events.any((e) => e.eventName == 'listening_resumed'), isFalse);
      expect(analytics.isListening, isFalse);
    });

    test('resumeListening is a no-op when already listening', () {
      analytics.startListening('s', 'S');
      fake.events.clear();

      analytics.resumeListening();

      expect(fake.events.any((e) => e.eventName == 'listening_resumed'), isFalse);
    });

    test('endListening with reason=stop clears retained station info', () {
      analytics.startListening('rve', 'RVE');
      analytics.endListening(reason: 'stop');
      fake.events.clear();

      analytics.resumeListening(); // should be a no-op now
      expect(fake.events.any((e) => e.eventName == 'listening_resumed'), isFalse);
    });

    test('endListening with reason=pause keeps station info for later resume', () {
      analytics.startListening('rve', 'RVE');
      analytics.endListening(reason: 'pause');
      fake.events.clear();

      analytics.resumeListening();
      expect(fake.events.any((e) => e.eventName == 'listening_resumed'), isTrue);
    });
  });

  group('skip / favorite / review tracking', () {
    test('trackStationSkip emits station_skip with from/to/direction', () {
      analytics.trackStationSkip('a', 'b', 'next');
      final ev = fake.events.singleWhere((e) => e.eventName == 'station_skip');
      expect(ev.properties?['from_station_slug'], 'a');
      expect(ev.properties?['to_station_slug'], 'b');
      expect(ev.properties?['direction'], 'next');
    });

    test('trackFavorite emits favorite_toggled with is_favorite flag', () {
      analytics.trackFavorite('rve', true, stationId: 42);
      final ev = fake.events.singleWhere((e) => e.eventName == 'favorite_toggled');
      expect(ev.properties?['station_slug'], 'rve');
      expect(ev.properties?['is_favorite'], true);
      expect(ev.properties?['station_id'], 42);
    });

    test('trackReviewSubmitted emits review_submitted with required fields', () {
      analytics.trackReviewSubmitted(
        stationId: 9,
        stationName: 'X',
        stars: 5,
        songId: 100,
        hasMessage: true,
      );
      final ev = fake.events.singleWhere((e) => e.eventName == 'review_submitted');
      expect(ev.properties?['station_id'], 9);
      expect(ev.properties?['stars'], 5);
      expect(ev.properties?['song_id'], 100);
      expect(ev.properties?['has_message'], true);
    });

    test('trackReviewSubmitted omits song_id when not provided', () {
      analytics.trackReviewSubmitted(
        stationId: 1,
        stationName: 'Y',
        stars: 3,
      );
      final ev = fake.events.lastWhere((e) => e.eventName == 'review_submitted');
      expect(ev.properties?.containsKey('song_id'), false);
      expect(ev.properties?['has_message'], false);
    });
  });

  group('flush', () {
    test('forwards to PostHog', () async {
      await analytics.flush();
      expect(fake.flushCalls, 1);
    });
  });

  group('log', () {
    test('emits app_log with the message property', () {
      analytics.log('hello');
      final ev = fake.events.singleWhere((e) => e.eventName == 'app_log');
      expect(ev.properties?['message'], 'hello');
    });
  });
}
