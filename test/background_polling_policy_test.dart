import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/background_polling_policy.dart';

/// Replaces the mirrored "Casting and background polling decisions" group of
/// the deleted metadata_timestamp_sync_test.dart (C14): the production rule
/// is now a pure function.
void main() {
  bool shouldPause({
    bool carConnected = false,
    bool casting = false,
    bool onMobileData = false,
    bool playing = true,
  }) =>
      BackgroundPollingPolicy.shouldPause(
        carConnected: carConnected,
        casting: casting,
        onMobileData: onMobileData,
        playing: playing,
      );

  group('BackgroundPollingPolicy.shouldPause', () {
    test('keeps polling while casting, although the local player is idle', () {
      expect(shouldPause(casting: true, playing: false), isFalse);
      expect(shouldPause(casting: true, onMobileData: true), isFalse);
    });

    test('keeps polling while a car shows the metadata', () {
      expect(shouldPause(carConnected: true, onMobileData: true), isFalse);
      expect(shouldPause(carConnected: true, playing: false), isFalse);
    });

    test('pauses on mobile data when no car or Cast screen shows the list', () {
      expect(shouldPause(onMobileData: true), isTrue);
    });

    test('keeps polling on wifi while playing locally', () {
      expect(shouldPause(), isFalse);
    });

    test('pauses when nothing plays and nothing shows the list', () {
      expect(shouldPause(playing: false), isTrue);
    });
  });
}
