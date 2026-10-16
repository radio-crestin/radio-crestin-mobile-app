import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Classifies and suppresses *benign* runtime errors so they neither crash the
/// app nor pollute PostHog error tracking.
///
/// PostHog's Flutter SDK auto-captures every `FlutterError` and every
/// `PlatformDispatcher` error. A handful of those are expected, recoverable
/// conditions — not bugs — and were drowning out real issues in production:
///
///   * `PlayerInterruptedException: Loading interrupted` — just_audio aborts an
///     in-flight load when the user switches stations quickly. Expected.
///     (PostHog 019d71a4…, 71 occ)
///   * `Bad state: Failed to load https://…` — extended_image artwork fetch
///     failed (offline / 404 / DNS). The UI already shows a placeholder.
///     (PostHog 019d8b2a…, 51 occ)
///   * `Failed to load font with url https://…` — google_fonts runtime fetch
///     failed offline. The text falls back to the default font. (019eac3c…)
///   * quick_actions `getLaunchAction` / `no_activity` — the Android
///     home-screen shortcut plugin has no foreground Activity (background or
///     secondary engine). (019d73e1…, 019d8e4e…, 145 occ)
///   * `Session activation failed` — iOS AVAudioSession could not activate
///     (transient OS state, e.g. an incoming call). just_audio retries.
///     (019d929b…)
///
/// [install] wraps the handlers PostHog installed during setup, so it MUST be
/// called AFTER `Posthog().setup(...)`. Benign errors are dropped; everything
/// else is forwarded to PostHog unchanged. The classification in [isBenign] is
/// a pure function so it can be unit tested directly.
class ErrorFilter {
  ErrorFilter._();

  static bool _installed = false;

  /// Wraps the current `FlutterError.onError` / `PlatformDispatcher.onError`
  /// (installed by PostHog) with a benign-error filter. Idempotent.
  static void install() {
    if (_installed) return;
    _installed = true;

    final downstreamFlutterHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (isBenign(details.exception, details.stack)) {
        if (kDebugMode) {
          developer.log('Suppressed benign error: ${details.exception}',
              name: 'ErrorFilter');
        }
        return;
      }
      downstreamFlutterHandler?.call(details);
    };

    final downstreamPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      if (isBenign(error, stack)) {
        if (kDebugMode) {
          developer.log('Suppressed benign async error: $error',
              name: 'ErrorFilter');
        }
        return true; // handled — don't report, don't surface as a crash
      }
      return downstreamPlatformHandler?.call(error, stack) ?? false;
    };
  }

  /// Whether [error] is a known-benign, recoverable condition that should not
  /// be reported. Pure and side-effect free — see the class doc for the
  /// rationale behind each rule.
  static bool isBenign(Object error, [StackTrace? stackTrace]) {
    final message = error.toString();
    final type = error.runtimeType.toString();

    // just_audio: a newer load superseded this one (rapid station switching).
    if (type == 'PlayerInterruptedException' ||
        message.contains('Loading interrupted')) {
      return true;
    }

    // google_fonts: runtime font fetch failed (offline / DNS). Checked before
    // the generic image rule so the intent stays explicit.
    if (message.contains('Failed to load font')) {
      return true;
    }

    // extended_image / NetworkImage: artwork fetch failed. The widget already
    // renders a placeholder; the thrown StateError is pure noise.
    if (message.contains('Failed to load') && _containsUrl(message)) {
      return true;
    }

    // quick_actions (Android): no foreground Activity, or the plugin isn't
    // attached to this engine.
    if (message.contains('getLaunchAction') ||
        message.contains('quick_action') ||
        message.contains('plugins.flutter.io/quick_actions')) {
      return true;
    }

    // audio_session (iOS): AVAudioSession activation failed transiently.
    if (message.contains('Session activation failed')) {
      return true;
    }

    return false;
  }

  /// Whether [error] should be reported to error tracking. The negation of
  /// [isBenign]; provided for call-site readability.
  static bool shouldReport(Object error, [StackTrace? stackTrace]) =>
      !isBenign(error, stackTrace);

  static bool _containsUrl(String text) =>
      text.contains('http://') || text.contains('https://');
}
