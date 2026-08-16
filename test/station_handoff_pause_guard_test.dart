import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/station_handoff_pause_guard.dart';

/// Regression suite for "Postul următor didn't start playing".
///
/// Device telemetry showed the advance itself worked perfectly — the next
/// station's stream loaded in 1174ms — and was then paused 526ms later by a
/// stray `MPRemoteCommandCenter` pause that iOS delivers when the YouTube
/// item's webview is destroyed. [StationHandoffPauseGuard] drops exactly that
/// one pause; every other pause, and any pause the user asks for, still works.
void main() {
  final t0 = DateTime(2026, 8, 16, 12, 17, 37);

  group('StationHandoffPauseGuard', () {
    test('does nothing until armed', () {
      final guard = StationHandoffPauseGuard();

      expect(guard.isArmed, isFalse);
      expect(guard.shouldIgnorePause(t0), isFalse);
    });

    test('drops the stray pause that lands inside the window', () {
      // Arrange: the advance left a YouTube item behind.
      final guard = StationHandoffPauseGuard();
      guard.arm(t0);

      // Act: the observed 526ms-later system pause.
      final ignored =
          guard.shouldIgnorePause(t0.add(const Duration(milliseconds: 526)));

      // Assert.
      expect(ignored, isTrue);
    });

    test('covers the worst observed delay (3.4s) but not much beyond', () {
      final guard = StationHandoffPauseGuard();

      guard.arm(t0);
      expect(
          guard.shouldIgnorePause(t0.add(const Duration(milliseconds: 3400))),
          isTrue);

      guard.arm(t0);
      expect(guard.shouldIgnorePause(t0.add(const Duration(seconds: 6))),
          isFalse,
          reason: 'a pause long after the handoff is a real one');
    });

    test('is ONE-SHOT: a second pause in the window goes through', () {
      // Arrange: armed once by the advance.
      final guard = StationHandoffPauseGuard();
      guard.arm(t0);

      // Act: the stray pause, then the user tapping pause a second later.
      final first = guard.shouldIgnorePause(t0.add(const Duration(seconds: 1)));
      final second = guard.shouldIgnorePause(t0.add(const Duration(seconds: 2)));

      // Assert: only the first is swallowed.
      expect(first, isTrue);
      expect(second, isFalse);
      expect(guard.isArmed, isFalse);
    });

    test('an expired window disarms instead of lingering', () {
      final guard = StationHandoffPauseGuard();
      guard.arm(t0);

      expect(guard.shouldIgnorePause(t0.add(const Duration(seconds: 10))),
          isFalse);
      expect(guard.isArmed, isFalse);
    });

    test('disarm() lets a user pause through immediately', () {
      // Arrange: armed, but the user taps pause right after the switch.
      final guard = StationHandoffPauseGuard();
      guard.arm(t0);

      // Act: pauseFromUser() disarms before pausing.
      guard.disarm();

      // Assert: nothing is swallowed.
      expect(guard.isArmed, isFalse);
      expect(guard.shouldIgnorePause(t0.add(const Duration(seconds: 1))),
          isFalse);
    });

    test('re-arming on a later advance restarts the window', () {
      final guard = StationHandoffPauseGuard();
      guard.arm(t0);
      guard.shouldIgnorePause(t0.add(const Duration(seconds: 1))); // consumed

      final t1 = t0.add(const Duration(minutes: 5));
      guard.arm(t1);

      expect(guard.shouldIgnorePause(t1.add(const Duration(seconds: 1))),
          isTrue);
    });

    test('a custom window is honored', () {
      final guard =
          StationHandoffPauseGuard(window: const Duration(seconds: 1));
      guard.arm(t0);

      expect(guard.shouldIgnorePause(t0.add(const Duration(seconds: 2))),
          isFalse);
    });
  });
}
