import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/appAudioHandler.dart';

void main() {
  group('AppAudioHandler.isRepeatLogged', () {
    test('logs the 1st, 10th, 100th and 1000th repeat', () {
      final logged = [
        for (var n = 0; n <= 1000; n++)
          if (AppAudioHandler.isRepeatLogged(n)) n,
      ];

      expect(logged, [1, 10, 100, 1000]);
    });

    test('never a negative or zero count', () {
      expect(AppAudioHandler.isRepeatLogged(0), isFalse);
      expect(AppAudioHandler.isRepeatLogged(-10), isFalse);
    });
  });
}
