import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/error_filter.dart';

/// Stand-in whose `runtimeType.toString()` matches just_audio's exception, so
/// the type-name branch is exercised without importing just_audio.
class PlayerInterruptedException implements Exception {
  final String message;
  PlayerInterruptedException(this.message);
  @override
  String toString() => message;
}

/// Reproduction + regression suite for the benign-error noise that was
/// polluting PostHog error tracking (and surfacing as crashes). Each case maps
/// to a real production issue; see [ErrorFilter] for the per-rule rationale.
void main() {
  group('ErrorFilter.isBenign — suppresses expected noise', () {
    test('just_audio PlayerInterruptedException (by type and by message)', () {
      // (PostHog 019d71a4…) — superseded load on rapid station switching.
      expect(
        ErrorFilter.isBenign(PlayerInterruptedException('Loading interrupted')),
        isTrue,
      );
      expect(ErrorFilter.isBenign(StateError('Loading interrupted')), isTrue);
    });

    test('extended_image artwork load failure', () {
      // (PostHog 019d8b2a…) — placeholder is already shown to the user.
      expect(
        ErrorFilter.isBenign(StateError(
            'Failed to load https://cdn.radiocrestin.ro/foo.png.')),
        isTrue,
      );
    });

    test('google_fonts runtime fetch failure', () {
      // (PostHog 019eac3c…) — text falls back to the default font.
      expect(
        ErrorFilter.isBenign(Exception(
            'Failed to load font with url https://fonts.gstatic.com/x.ttf')),
        isTrue,
      );
    });

    test('quick_actions no-activity and missing-plugin variants', () {
      // (PostHog 019d73e1… / 019d8e4e…)
      expect(
        ErrorFilter.isBenign(Exception(
            'PlatformException(quick_action_getlaunchaction_no_activity, '
            'There is no activity available when launching action, null, null)')),
        isTrue,
      );
      expect(
        ErrorFilter.isBenign(Exception(
            'MissingPluginException(No implementation found for method '
            'getLaunchAction on channel plugins.flutter.io/quick_actions)')),
        isTrue,
      );
    });

    test('audio_session iOS activation failure', () {
      // (PostHog 019d929b…)
      expect(
        ErrorFilter.isBenign(Exception(
            'PlatformException(561015905, Session activation failed, null, null)')),
        isTrue,
      );
    });
  });

  group('ErrorFilter.isBenign — preserves real bugs', () {
    test('our own ArgumentError (the clamp crash) is still reported', () {
      expect(
        ErrorFilter.isBenign(ArgumentError('Invalid argument(s): 140.0')),
        isFalse,
      );
    });

    test('generic state/range/exception errors are reported', () {
      expect(ErrorFilter.isBenign(StateError('No element')), isFalse);
      expect(ErrorFilter.isBenign(RangeError('index out of range')), isFalse);
      expect(ErrorFilter.isBenign(Exception('Something genuinely broke')),
          isFalse);
    });

    test('RenderFlex overflow is NOT suppressed (real layout bug)', () {
      expect(
        ErrorFilter.isBenign(
            FlutterError('A RenderFlex overflowed by 3.2 pixels on the right.')),
        isFalse,
      );
    });

    test('a non-image "Failed to load" without a URL is reported', () {
      // Guards against over-matching: the image rule requires a URL.
      expect(ErrorFilter.isBenign(StateError('Failed to load data')), isFalse);
    });
  });

  group('ErrorFilter.shouldReport', () {
    test('is the negation of isBenign', () {
      final benign = PlayerInterruptedException('Loading interrupted');
      final real = ArgumentError('boom');
      expect(ErrorFilter.shouldReport(benign), isFalse);
      expect(ErrorFilter.shouldReport(real), isTrue);
    });
  });
}
