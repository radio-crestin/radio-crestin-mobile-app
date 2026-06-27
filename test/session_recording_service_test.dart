import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/services/session_recording_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionRecordingService.load', () {
    // An empty device id short-circuits the background network refresh, so
    // these tests exercise only the cached-read path used at startup.

    test('defaults to disabled with full sample rate when nothing is cached',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final result = await SessionRecordingService.instance.load(prefs, '');

      expect(result.enabled, isFalse);
      expect(result.sampleRate, 1.0);
    });

    test('returns the values cached from a previous launch', () async {
      SharedPreferences.setMockInitialValues({
        'session_recording_enabled': true,
        'session_recording_sample_rate': 0.5,
      });
      final prefs = await SharedPreferences.getInstance();

      final result = await SessionRecordingService.instance.load(prefs, '');

      expect(result.enabled, isTrue);
      expect(result.sampleRate, 0.5);
    });
  });
}
