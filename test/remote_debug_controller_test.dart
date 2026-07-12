import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/services/remote_debug_controller.dart';

void main() {
  group('RemoteDebugConfig.parse', () {
    test('full payload maps every key', () {
      final config = RemoteDebugConfig.parse(
        enabled: true,
        payload: {
          'verboseLogs': true,
          'sessionReplay': true,
          'wifiOnly': false,
          'uploadLocalLogs': true,
        },
      );

      expect(config.enabled, isTrue);
      expect(config.verboseLogs, isTrue);
      expect(config.sessionReplay, isTrue);
      expect(config.wifiOnly, isFalse);
      expect(config.uploadLocalLogs, isTrue);
    });

    test('missing keys default to false — including wifiOnly', () {
      final config = RemoteDebugConfig.parse(enabled: true, payload: {});

      expect(config.enabled, isTrue);
      expect(config.verboseLogs, isFalse);
      expect(config.sessionReplay, isFalse);
      expect(config.wifiOnly, isFalse);
      expect(config.uploadLocalLogs, isFalse);
    });

    test('null or malformed payload defaults everything to false', () {
      for (final payload in [null, 'oops', 42, <Object>[]]) {
        final config = RemoteDebugConfig.parse(enabled: true, payload: payload);
        expect(config.enabled, isTrue, reason: 'payload $payload');
        expect(config.verboseLogs, isFalse, reason: 'payload $payload');
        expect(config.sessionReplay, isFalse, reason: 'payload $payload');
        expect(config.wifiOnly, isFalse, reason: 'payload $payload');
        expect(config.uploadLocalLogs, isFalse, reason: 'payload $payload');
      }
    });

    test('non-bool values are treated as false', () {
      final config = RemoteDebugConfig.parse(
        enabled: true,
        payload: {'verboseLogs': 'yes', 'sessionReplay': 1},
      );
      expect(config.verboseLogs, isFalse);
      expect(config.sessionReplay, isFalse);
    });

    test('disabled flag ignores the payload entirely', () {
      final config = RemoteDebugConfig.parse(
        enabled: false,
        payload: {'verboseLogs': true, 'sessionReplay': true},
      );
      expect(config, same(RemoteDebugConfig.disabled));
      expect(config.enabled, isFalse);
      expect(config.verboseLogs, isFalse);
    });
  });
}
