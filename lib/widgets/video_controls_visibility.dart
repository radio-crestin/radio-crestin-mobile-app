/// The single place every video surface's control-visibility behaviour is
/// configured — the inline player, the mobile fullscreen route and the TV
/// chrome all read their timing and their show/hide rule from here.
///
/// Keeping them together is the point: the three surfaces looked independent
/// but are one product decision ("how long do controls linger over a moving
/// picture?"), and when the numbers lived apart they drifted.
library;

/// Which surface the controls are drawn on — what decides how long they stay.
enum VideoControlsSurface {
  /// The small video inside the full player, sharing the screen with the
  /// title, transport and track list.
  inline,

  /// The mobile fullscreen route.
  fullscreen,

  /// The TV / desktop chrome, driven by a remote rather than a finger.
  tv,
}

/// Inactivity delay before the INLINE video surface fades its controls out.
///
/// Much longer than the others on purpose: inline, the controls are not in the
/// way of anything — the video only occupies a band of the screen — so they
/// only need to step aside once the user has clearly settled into watching.
const Duration kInlineControlsAutoHideDelay = Duration(seconds: 20);

/// Inactivity delay for the mobile FULLSCREEN overlay.
///
/// Five seconds, not three: three is long enough to read a control but not to
/// decide to use one, and people repeatedly had to tap the screen again just to
/// get the scrubber back. Matches [kTvVideoChromeAutoHideDelay], so the same
/// gesture on a phone and a remote on the TV feel like the same product.
const Duration kFullscreenControlsAutoHideDelay = Duration(seconds: 5);

/// Idle delay before the TV video chrome (back button, title scrim and the
/// transport row) fades out over a moving picture.
///
/// On a 10-foot screen the chrome is a band of UI sitting on top of the
/// content, so it has to step aside once the user has settled into watching.
/// Any remote press brings it straight back, and it stays pinned while paused
/// or buffering (see [shouldShowVideoControls]).
const Duration kTvVideoChromeAutoHideDelay = Duration(seconds: 5);

/// The inactivity delay for [surface]. Pure, so the timing contract is
/// unit-testable without pumping a single timer.
Duration videoControlsAutoHideDelayFor(VideoControlsSurface surface) =>
    switch (surface) {
      VideoControlsSurface.inline => kInlineControlsAutoHideDelay,
      VideoControlsSurface.fullscreen => kFullscreenControlsAutoHideDelay,
      VideoControlsSurface.tv => kTvVideoChromeAutoHideDelay,
    };

/// The inactivity delay for the mobile overlay in either of its two shapes.
Duration videoControlsAutoHideDelay({required bool isFullscreen}) =>
    videoControlsAutoHideDelayFor(isFullscreen
        ? VideoControlsSurface.fullscreen
        : VideoControlsSurface.inline);

/// Whether the auto-hiding controls should currently be shown (and be
/// hit-testable).
///
/// [userVisible] is the inactivity timer's own state — false once the timer
/// elapsed, true again after any interaction. Playback state overrides it:
/// while PAUSED or buffering the controls always stay up, so a paused video
/// never strands the user without a scrubber. Pure so the whole show/hide
/// decision is testable without pumping timers.
bool shouldShowVideoControls({
  required bool userVisible,
  required bool playing,
  required bool buffering,
}) =>
    userVisible || !playing || buffering;
