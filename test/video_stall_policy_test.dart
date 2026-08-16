import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/appAudioHandler.dart';

/// Unit tests for [VideoStallPolicy] — the post-first-frame stall escalation
/// for video mode (TV channels and video playlist items).
///
/// The startup fallback watchdog only covers the cold start (no first frame
/// yet). Once a frame renders it disarms, so a mid-stream stall needs its own
/// recovery: reconnect the picture once, then fall back to audio-only if it
/// stalls again in the same session. These tests lock that escalation in.
void main() {
  group('VideoStallPolicy.decide — escalation while playing', () {
    test('first stall (no reconnect spent) → reconnect in place', () {
      // Arrange: a rendered, playing stream that is now buffering, with no
      // reconnect yet spent this session.
      // Act.
      final action = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: true,
        playIntended: true,
        reconnectAttempts: 0,
      );
      // Assert.
      expect(action, VideoStallAction.reconnect);
    });

    test('second stall (one reconnect already spent) → audio fallback', () {
      // Arrange: same stall, but the one in-place reconnect is used up.
      // Act.
      final action = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: true,
        playIntended: true,
        reconnectAttempts: 1,
      );
      // Assert.
      expect(action, VideoStallAction.fallback);
    });

    test('further stalls stay on fallback (never reconnect again)', () {
      // Arrange + Act.
      final action = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: true,
        playIntended: true,
        reconnectAttempts: 2,
      );
      // Assert.
      expect(action, VideoStallAction.fallback);
    });
  });

  group('VideoStallPolicy.decide — guard clauses (no action)', () {
    test('user-paused item is never reconnected', () {
      // Arrange: buffering ahead while paused is not a stall to recover from.
      // Act.
      final action = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: true,
        playIntended: false,
        reconnectAttempts: 0,
      );
      // Assert.
      expect(action, VideoStallAction.none);
    });

    test('pre-first-frame belongs to the startup watchdog → no action', () {
      // Arrange: no frame yet — the cold-start watchdog owns this window.
      // Act.
      final action = VideoStallPolicy.decide(
        hasRenderedFrame: false,
        buffering: true,
        playIntended: true,
        reconnectAttempts: 0,
      );
      // Assert.
      expect(action, VideoStallAction.none);
    });

    test('not buffering (e.g. VOD paused at end of buffer) → no action', () {
      // Arrange: playing intent but the picture is not actually stalled.
      // Act.
      final action = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: false,
        playIntended: true,
        reconnectAttempts: 0,
      );
      // Assert.
      expect(action, VideoStallAction.none);
    });

    test('a spent reconnect budget is ignored when not actually stalled', () {
      // Arrange: even with a reconnect spent, a non-buffering stream is fine.
      // Act.
      final action = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: false,
        playIntended: true,
        reconnectAttempts: 1,
      );
      // Assert.
      expect(action, VideoStallAction.none);
    });
  });

  group('VideoStallPolicy — session escalation sequence', () {
    test('reconnect first, fallback second as the counter advances', () {
      // Arrange: a fresh session starts at zero reconnects.
      var reconnects = 0;

      // Act + Assert: the first stall reconnects and spends the budget.
      final first = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: true,
        playIntended: true,
        reconnectAttempts: reconnects,
      );
      expect(first, VideoStallAction.reconnect);
      reconnects++; // the handler increments on a reconnect action

      // Act + Assert: the next stall in the same session escalates to fallback.
      final second = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: true,
        playIntended: true,
        reconnectAttempts: reconnects,
      );
      expect(second, VideoStallAction.fallback);

      // Act + Assert: a new session resets the counter, so it reconnects again.
      reconnects = 0; // the handler resets on each fresh _enterVideoMode
      final newSession = VideoStallPolicy.decide(
        hasRenderedFrame: true,
        buffering: true,
        playIntended: true,
        reconnectAttempts: reconnects,
      );
      expect(newSession, VideoStallAction.reconnect);
    });
  });
}
