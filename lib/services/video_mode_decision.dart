/// Pure policy deciding whether playback should run in "video mode".
///
/// Video mode uses media_kit (libmpv) as the single audio+video source, giving
/// perfect A/V sync for TV channels and video playlist items. It is mutually
/// exclusive with the just_audio path — extracted here so the (small) rule set
/// is unit-testable without spinning up either real player.
///
/// The rule: engage video mode only for video content while the app is
/// foregrounded and neither a car (CarPlay / Android Auto) nor a Cast session
/// is connected. In every other case audio-only playback via just_audio is the
/// correct behavior:
///   - a car head unit / Cast receiver cannot render the app's inline video,
///     so we send it the audio track instead;
///   - a backgrounded app should not keep a video decoder alive — the user is
///     only hearing audio, so we hand off to just_audio (see the handoff logic
///     in [AppAudioHandler.onAppLifecycleChanged]).
class VideoModeDecision {
  const VideoModeDecision._();

  /// Returns true when playback should use media_kit video mode right now.
  ///
  /// [isVideoContent] is true for a TV station or a `video`-type playlist item.
  /// A `youtube` playlist item is NOT video content for this decision — it is
  /// rendered by the UI's inline iframe player, not media_kit.
  static bool shouldUseVideoMode({
    required bool isVideoContent,
    required bool isForeground,
    required bool isCarConnected,
    required bool isCasting,
  }) {
    if (!isVideoContent) return false;
    if (!isForeground) return false;
    if (isCarConnected || isCasting) return false;
    return true;
  }

  /// Returns true when the app returning to the foreground should hand playback
  /// back from audio-only to media_kit video mode.
  ///
  /// This is [shouldUseVideoMode] with `isForeground: true` (the app just
  /// resumed) plus the crucial extra guard [hasFallenBackForUrl]: a URL that
  /// genuinely failed to render earlier (decode error, no first frame) is pinned
  /// to audio-only, so the resume must NOT re-attempt video for it and fight the
  /// fallback on every foreground.
  ///
  /// Backgrounding alone must never set that fallback flag — only a real
  /// playback failure does — so a plain background→foreground round-trip of a
  /// healthy TV stream always returns true here and the video seamlessly
  /// resumes.
  static bool shouldResumeVideoOnForeground({
    required bool isVideoContent,
    required bool isCarConnected,
    required bool isCasting,
    required bool hasFallenBackForUrl,
  }) {
    if (hasFallenBackForUrl) return false;
    return shouldUseVideoMode(
      isVideoContent: isVideoContent,
      isForeground: true,
      isCarConnected: isCarConnected,
      isCasting: isCasting,
    );
  }
}
