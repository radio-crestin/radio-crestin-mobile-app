import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/session_replay_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionReplayController.shouldRecord', () {
    test('always variant records on WiFi', () {
      expect(
        SessionReplayController.shouldRecord(
          variant: 'always',
          wifiOnly: true,
          onWifi: true,
          errorOccurred: false,
        ),
        isTrue,
      );
    });

    test('always variant is blocked on cellular when wifiOnly', () {
      expect(
        SessionReplayController.shouldRecord(
          variant: 'always',
          wifiOnly: true,
          onWifi: false,
          errorOccurred: false,
        ),
        isFalse,
      );
    });

    test('always variant records on cellular when wifiOnly is false', () {
      expect(
        SessionReplayController.shouldRecord(
          variant: 'always',
          wifiOnly: false,
          onWifi: false,
          errorOccurred: false,
        ),
        isTrue,
      );
    });

    test('on-error variant waits for an error before recording', () {
      expect(
        SessionReplayController.shouldRecord(
          variant: 'on-error',
          wifiOnly: true,
          onWifi: true,
          errorOccurred: false,
        ),
        isFalse,
      );
      expect(
        SessionReplayController.shouldRecord(
          variant: 'on-error',
          wifiOnly: true,
          onWifi: true,
          errorOccurred: true,
        ),
        isTrue,
      );
    });

    test('disabled and unknown variants never record', () {
      for (final variant in <String?>['disabled', null, 'other']) {
        expect(
          SessionReplayController.shouldRecord(
            variant: variant,
            wifiOnly: false,
            onWifi: true,
            errorOccurred: true,
          ),
          isFalse,
          reason: 'variant $variant should not record',
        );
      }
    });
  });

  group('SessionReplayController.shouldRecordWithOverride', () {
    test('remote force records even for disabled variant on mobile data', () {
      expect(
        SessionReplayController.shouldRecordWithOverride(
          variant: 'disabled',
          wifiOnly: true,
          onWifi: false,
          errorOccurred: false,
          remoteForce: true,
          remoteWifiOnly: false,
        ),
        isTrue,
      );
    });

    test('remote force honors its own wifiOnly gate', () {
      expect(
        SessionReplayController.shouldRecordWithOverride(
          variant: 'always',
          wifiOnly: false,
          onWifi: false,
          errorOccurred: false,
          remoteForce: true,
          remoteWifiOnly: true,
        ),
        isFalse,
      );
    });

    test('without remote force it defers to the variant decision', () {
      expect(
        SessionReplayController.shouldRecordWithOverride(
          variant: 'always',
          wifiOnly: true,
          onWifi: true,
          errorOccurred: false,
          remoteForce: false,
          remoteWifiOnly: false,
        ),
        isTrue,
      );
      expect(
        SessionReplayController.shouldRecordWithOverride(
          variant: 'disabled',
          wifiOnly: false,
          onWifi: true,
          errorOccurred: true,
          remoteForce: false,
          remoteWifiOnly: false,
        ),
        isFalse,
      );
    });
  });

  group('SessionReplayController.parseWifiOnly', () {
    test('reads the wifiOnly flag from the payload', () {
      expect(SessionReplayController.parseWifiOnly({'wifiOnly': false}), isFalse);
      expect(SessionReplayController.parseWifiOnly({'wifiOnly': true}), isTrue);
    });

    test('defaults to true for missing or malformed payloads', () {
      expect(SessionReplayController.parseWifiOnly(null), isTrue);
      expect(SessionReplayController.parseWifiOnly('nope'), isTrue);
      expect(SessionReplayController.parseWifiOnly({'other': 1}), isTrue);
    });
  });

  group('SessionReplayController.loadCache / enableReplayAtSetup', () {
    test('defaults to enabling replay at setup when nothing is cached',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await SessionReplayController.instance.loadCache(prefs);

      expect(SessionReplayController.instance.enableReplayAtSetup, isTrue);
    });

    test('a cached disabled variant skips replay at setup', () async {
      SharedPreferences.setMockInitialValues({
        'session_replay_variant': 'disabled',
      });
      final prefs = await SharedPreferences.getInstance();

      await SessionReplayController.instance.loadCache(prefs);

      expect(SessionReplayController.instance.enableReplayAtSetup, isFalse);
    });
  });
}
