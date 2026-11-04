import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/session_replay_controller.dart';

/// Records what the controller asked of PostHog.
class _FakeRecorder {
  final List<String> calls = [];
  bool? armed;
  PostHogFeatureFlagResult? flag;

  SessionReplayController controller({bool platformSupported = true}) =>
      SessionReplayController(
        platformSupported: platformSupported,
        readFlag: () async => flag,
        startRecording: () async => calls.add('start'),
        stopRecording: () async => calls.add('stop'),
        armCapture: (value) => armed = value,
      );
}

PostHogFeatureFlagResult _flag(String? variant, [Object? payload]) =>
    PostHogFeatureFlagResult(
      key: SessionReplayController.flagKey,
      enabled: variant != null,
      variant: variant,
      payload: payload,
    );

Future<SharedPreferences> _prefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

const _onErrorCache = {'session_replay_variant': 'on-error'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReplayPolicy.fromFlag', () {
    test('reads the two recording variants', () {
      expect(ReplayPolicy.fromFlag('on-error', null).mode, ReplayMode.onError);
      expect(ReplayPolicy.fromFlag('always', null).mode, ReplayMode.always);
    });

    test('anything else is off', () {
      for (final variant in [null, 'disabled', 'control', '']) {
        expect(ReplayPolicy.fromFlag(variant, {'wifiOnly': false}).installs,
            isFalse,
            reason: 'variant $variant');
      }
    });

    test('defaults to Wi-Fi only and a 10 minute limit', () {
      for (final payload in [null, 'oops', 42, <Object>[], {}]) {
        final policy = ReplayPolicy.fromFlag('on-error', payload);
        expect(policy.wifiOnly, isTrue, reason: 'payload $payload');
        expect(policy.maxDuration, const Duration(minutes: 10),
            reason: 'payload $payload');
      }
    });

    test('payload sets Wi-Fi only and the limit, 0 for none', () {
      final policy =
          ReplayPolicy.fromFlag('always', {'wifiOnly': false, 'maxMinutes': 3});
      expect(policy.wifiOnly, isFalse);
      expect(policy.maxDuration, const Duration(minutes: 3));
      expect(ReplayPolicy.fromFlag('always', {'maxMinutes': 0}).maxDuration,
          isNull);
    });
  });

  group('ReplayPolicy.shouldRecord', () {
    bool record(ReplayPolicy policy,
            {bool onWifi = true, bool error = false, bool limit = false}) =>
        policy.shouldRecord(
            onWifi: onWifi, errorOccurred: error, limitReached: limit);

    final onError = ReplayPolicy.fromFlag('on-error', null);
    final always = ReplayPolicy.fromFlag('always', null);

    test('on-error waits for an error', () {
      expect(record(onError), isFalse);
      expect(record(onError, error: true), isTrue);
    });

    test('always records from the start', () {
      expect(record(always), isTrue);
    });

    test('Wi-Fi only pauses on mobile data', () {
      expect(record(always, onWifi: false), isFalse);
      final anyNetwork = ReplayPolicy.fromFlag('always', {'wifiOnly': false});
      expect(record(anyNetwork, onWifi: false), isTrue);
    });

    test('the time limit stops recording', () {
      expect(record(always, limit: true), isFalse);
    });

    test('off never records', () {
      expect(record(ReplayPolicy.off, error: true), isFalse);
    });
  });

  group('SessionReplayController setup', () {
    test('a first launch does not install replay', () async {
      final controller = _FakeRecorder().controller()
        ..loadCache(await _prefs({}));
      expect(controller.installAtSetup, isFalse);
    });

    test('a device the flag picked last launch installs it', () async {
      final controller = _FakeRecorder().controller()
        ..loadCache(await _prefs(_onErrorCache));
      expect(controller.installAtSetup, isTrue);
    });

    test('never installs off Android and iOS', () async {
      final controller = _FakeRecorder().controller(platformSupported: false)
        ..loadCache(await _prefs(_onErrorCache));
      expect(controller.installAtSetup, isFalse);
    });

    test('the live flag is cached for the next launch', () async {
      final recorder = _FakeRecorder()
        ..flag = _flag('always', {'wifiOnly': false});
      final prefs = await _prefs({});
      await (recorder.controller()..loadCache(prefs)).onFlagsLoaded();

      final next = _FakeRecorder().controller()..loadCache(prefs);
      expect(next.installAtSetup, isTrue);
    });

    test('a device the flag dropped is not installed next launch', () async {
      final recorder = _FakeRecorder()..flag = null;
      final prefs = await _prefs(_onErrorCache);
      await (recorder.controller()..loadCache(prefs)).onFlagsLoaded();

      final next = _FakeRecorder().controller()..loadCache(prefs);
      expect(next.installAtSetup, isFalse);
    });
  });

  group('SessionReplayController recording', () {
    late NetworkService network;
    late _FakeRecorder recorder;

    setUp(() {
      network = NetworkService();
      recorder = _FakeRecorder();
    });

    Future<SessionReplayController> started(Map<String, Object> cache) async {
      final controller = recorder.controller()..loadCache(await _prefs(cache));
      controller.start(installed: controller.installAtSetup, network: network);
      return controller;
    }

    test('stops the recording setup started, and disarms capture', () async {
      final controller = await started(_onErrorCache);
      expect(recorder.calls, ['stop']);
      expect(recorder.armed, isFalse);
      controller.dispose();
    });

    test('on-error starts recording at the first error', () async {
      final controller = await started(_onErrorCache);
      controller
        ..notifyErrorCaptured()
        ..notifyErrorCaptured();
      expect(recorder.calls, ['stop', 'start']);
      expect(recorder.armed, isTrue);
      controller.dispose();
    });

    test('pauses on mobile data and resumes on Wi-Fi', () async {
      final controller = await started({'session_replay_variant': 'always'});
      network.isOnMobileData.add(true);
      await pumpEventQueue();
      network.isOnMobileData.add(false);
      await pumpEventQueue();
      expect(recorder.calls, ['start', 'stop', 'start']);
      controller.dispose();
    });

    test('does nothing when replay was not installed', () async {
      final controller = await started({});
      controller.notifyErrorCaptured();
      expect(recorder.calls, isEmpty);
      expect(recorder.armed, isNull);
    });

    test('a device the live flag dropped stops at once', () async {
      final controller = await started({'session_replay_variant': 'always'});
      recorder.flag = null;
      await controller.onFlagsLoaded();
      expect(recorder.calls, ['start', 'stop']);
      controller.dispose();
    });

    test('stops when the time limit is reached', () {
      fakeAsync((async) {
        late SessionReplayController controller;
        _prefs({
          'session_replay_variant': 'always',
          'session_replay_payload': '{"maxMinutes": 2}',
        }).then((prefs) {
          controller = recorder.controller()..loadCache(prefs);
          controller.start(installed: true, network: network);
        });
        async.flushMicrotasks();
        expect(recorder.calls, ['start']);

        async.elapse(const Duration(minutes: 2));
        expect(recorder.calls, ['start', 'stop']);

        controller.notifyErrorCaptured();
        expect(recorder.calls, ['start', 'stop']);
        controller.dispose();
      });
    });
  });
}
