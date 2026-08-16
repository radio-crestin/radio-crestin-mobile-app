import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/cast_service.dart';

void main() {
  group('CastService discovery gating', () {
    test('iOS defers discovery to the first cast-button tap', () {
      // Bonjour browsing raises the iOS "Local Network" prompt, so nothing
      // may scan before the user asks to cast.
      expect(CastService(autoStartDiscovery: false).autoStartDiscovery,
          isFalse);
    });

    test('other platforms keep scanning from startup', () {
      expect(CastService(autoStartDiscovery: true).autoStartDiscovery, isTrue);
    });

    test('the default follows the platform', () {
      expect(CastService().autoStartDiscovery, !Platform.isIOS);
    });
  });
}
