import 'analytics_service.dart';
import 'network_service.dart';

/// What went wrong in a [PlaybackFailure].
enum PlaybackFailureKind {
  /// Every stream of the station failed a full pass. The user sees the
  /// connection error while playback keeps retrying.
  allStreamsFailed('all streams failed'),

  /// A non-HLS stream ended on its own, which stops playback.
  streamEnded('stream ended unexpectedly'),

  /// Every item of a playlist failed in a row, which stops playback.
  playlistFailed('every playlist item failed');

  const PlaybackFailureKind(this.description);

  /// Human-readable summary, used as the exception message.
  final String description;
}

/// A playback failure the user notices, reported to PostHog Error Tracking
/// as a handled exception so it sits next to crashes instead of only in logs.
///
/// The message carries just the kind and reason — never the station or URL —
/// so each kind groups into a single issue; the specifics ride on the event.
class PlaybackFailure implements Exception {
  /// Creates a failure of [kind], optionally narrowed by [reason].
  const PlaybackFailure(this.kind, {this.reason});

  /// What went wrong.
  final PlaybackFailureKind kind;

  /// Why, when known (e.g. `timeout`), so distinct causes become distinct
  /// issues.
  final String? reason;

  @override
  String toString() =>
      reason == null ? kind.description : '${kind.description} ($reason)';

  /// Reports a [kind] failure with [properties] (station, stream, error).
  ///
  /// Skipped while the device is offline: failing to play then is expected,
  /// not a bug, and would only bury the actionable issues.
  static void report(
    PlaybackFailureKind kind, {
    String? reason,
    Map<String, Object?> properties = const {},
  }) {
    if (NetworkService.instance.isOffline.value) return;
    final failure = PlaybackFailure(kind, reason: reason);
    AnalyticsService.instance.captureException(
      failure,
      StackTrace.current,
      context: 'playback',
      properties: {
        r'$issue_name': 'Playback: $failure',
        ...properties,
      },
    );
  }
}
