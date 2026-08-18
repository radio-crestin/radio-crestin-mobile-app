/// What to do about a video stream whose playback CLOCK has stopped moving.
enum FrozenClockAction {
  /// Cheapest recovery: jump back to the live edge (live), or nudge the
  /// engine back into playing (on-demand). Keeps the connection.
  seekToLiveEdge,

  /// Re-open the same media in place — a new connection, same content.
  reload,

  /// Nothing worked; hand the content to the audio-only fallback chain.
  giveUp,
}

/// Detects and escalates recovery for video that has frozen mid-playback.
///
/// The engine's own "buffering" flag cannot catch every stall: a frozen
/// stream can keep reporting *playing, not buffering* while its clock stands
/// still — measured on tvOS, where it was the whole reason the picture froze
/// with no spinner and no recovery. Comparing successive playback positions
/// is the only signal that reflects what the user actually sees, so this
/// policy works off the clock and complements the buffering-stall watchdog
/// ([VideoStallPolicy]) rather than replacing it.
///
/// Mirrors `StallRecoveryPolicy` in the Apple TV app so both platforms
/// recover from a frozen HLS stream the same way.
class VideoClockStallPolicy {
  const VideoClockStallPolicy._();

  /// How often the playback clock is sampled.
  static const Duration sampleInterval = Duration(seconds: 2);

  /// Clock movement below this between two samples counts as "frozen".
  static const Duration minimumProgress = Duration(milliseconds: 50);

  /// How long the clock may stand still before we intervene. Long enough not
  /// to fight the engine's own rebuffering, short enough that nobody sits
  /// staring at a dead frame.
  static const Duration stallGrace = Duration(seconds: 6);

  /// Whether the clock advanced between two samples.
  static bool moved({required Duration previous, required Duration current}) =>
      (current - previous).abs() >= minimumProgress;

  /// Whether a clock frozen for [frozenFor] counts as a stall worth acting on.
  static bool isStalled(Duration frozenFor) => frozenFor >= stallGrace;

  /// Escalation for the [attempt]-th consecutive stall (1-based): a cheap
  /// re-seek first, then a full reload, then hand back to the audio fallback.
  static FrozenClockAction action(int attempt) {
    if (attempt <= 1) return FrozenClockAction.seekToLiveEdge;
    if (attempt == 2) return FrozenClockAction.reload;
    return FrozenClockAction.giveUp;
  }
}
