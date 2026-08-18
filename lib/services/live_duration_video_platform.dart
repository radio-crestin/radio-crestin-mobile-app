// video_player_platform_interface ships as a transitive dependency of
// video_player; this decorator needs it directly to wrap the platform instance.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The duration a live stream ends up reported with — an INDEFINITE length.
///
/// Both platforms send `-9223372036854775807` milliseconds (iOS
/// `CMTIME_IS_INDEFINITE`, Android `C.TIME_UNSET`), and the platform channel's
/// `Duration(milliseconds: …)` conversion overflows that to exactly 1000
/// microseconds. Upstream: flutter/flutter#102366, #107882 (both still open).
const Duration kIndefiniteDurationSentinel = Duration(microseconds: 1000);

/// What [LiveDurationVideoPlatform] substitutes for an indefinite duration.
///
/// Large enough that no playhead ever reaches it (so `VideoPlayerController`
/// never clamps, never latches `isCompleted`, and never rewinds on `play()`),
/// finite so every `Duration` comparison inside video_player still works, and
/// far past [kMaxPlausibleMediaDuration] so it can never be mistaken for a real
/// media length by anything downstream.
const Duration kIndefiniteDurationStandIn = Duration(days: 30000);

/// Longest length this app will believe as a real media duration.
///
/// Anything at or beyond this is the indefinite-duration artefact or the
/// [kIndefiniteDurationStandIn] that replaced it — never a video someone made.
const Duration kMaxPlausibleMediaDuration = Duration(days: 1);

/// Whether [d] is a usable media length: strictly positive, shorter than
/// [kMaxPlausibleMediaDuration], and not the [kIndefiniteDurationSentinel]
/// artefact. [Duration.zero] means "not resolved yet", which is equally
/// unusable.
bool isPlausibleMediaDuration(Duration? d) =>
    d != null &&
    d > Duration.zero &&
    d < kMaxPlausibleMediaDuration &&
    d != kIndefiniteDurationSentinel;

/// Whether [d] is the indefinite-duration artefact a live stream arrives with.
bool isIndefiniteReportedDuration(Duration? d) =>
    d != null && (d <= Duration.zero || d == kIndefiniteDurationSentinel);

/// A [VideoPlayerPlatform] decorator that rewrites the indefinite-duration
/// artefact out of the event stream, at the ONE point where it enters Dart.
///
/// ## The invariant
///
/// `VideoPlayerController` may never see a media length it can reach. Every
/// live-stream bug this app has had traces back to `value.duration == 1ms`:
///
///   * `play()` starts with `if (value.position == value.duration) seekTo(0)`,
///     so on a live stream EVERY resume injected a native seek to the start of
///     the DVR window — pause→play was broken outright (video_player ~L729).
///   * `_updatePosition` clamps the playhead to the duration, so the clock
///     stood still at 0:00 and the stall watchdogs saw a frozen picture.
///   * The same method sets `isCompleted: position == value.duration`, which
///     latched ~100ms into playback: the transport button flipped to "play"
///     mid-stream, controls stopped auto-hiding, playlists skipped instantly.
///
/// None of that is suppressible from outside the controller, because the
/// controller derives it all from the value it built from the platform event.
/// So the fix belongs BELOW the controller: when an `initialized` event carries
/// an indefinite length, this decorator swaps in [kIndefiniteDurationStandIn]
/// (30000 days). Position never reaches it, `isCompleted` never latches, and
/// `play()` never rewinds — with no fork of video_player.
///
/// ## Keeping the truth
///
/// Substituting a length would be a lie if it were the only record, so the
/// decorator REMEMBERS which players were indefinite ([isIndefinite]).
/// `VideoPlaybackService` reads that back to decide what is live/unseekable and
/// keeps publishing [Duration.zero] — "unknown" — to the UI, never the
/// stand-in. [isPlausibleMediaDuration] rejects the stand-in as well, so any
/// code path that never consults this class still cannot mistake it for a real
/// duration.
class LiveDurationVideoPlatform extends VideoPlayerPlatform {
  @visibleForTesting
  LiveDurationVideoPlatform(this._delegate);

  final VideoPlayerPlatform _delegate;

  /// Ids of players whose `initialized` event carried an indefinite length.
  final Set<int> _indefinitePlayers = <int>{};

  /// playerId → the media URL it was created for, so the record can be answered
  /// by URL: `VideoPlayerController.playerId` is `@visibleForTesting`, and the
  /// URL is what `VideoPlaybackService` knows about the media it opened anyway.
  final Map<int, String> _urlOf = <int, String>{};

  /// URLs currently backed by an indefinite player.
  final Set<String> _indefiniteUrls = <String>{};

  /// The platform instance this decorator forwards to (tests assert on it).
  @visibleForTesting
  VideoPlayerPlatform get delegate => _delegate;

  /// Wraps [VideoPlayerPlatform.instance] once, before any controller exists.
  ///
  /// Idempotent: a second call while the decorator is already installed is a
  /// no-op, so it is safe (and intended) to call this at the top of every code
  /// path that is about to create a controller.
  static void ensureInstalled() {
    final current = VideoPlayerPlatform.instance;
    if (current is LiveDurationVideoPlatform) return;
    VideoPlayerPlatform.instance = LiveDurationVideoPlatform(current);
  }

  /// Whether the player behind [playerId] reported an indefinite length.
  ///
  /// `false` when the decorator is not installed — callers must keep their own
  /// duration test as the fallback (see [isPlausibleMediaDuration]).
  static bool isIndefinite(int playerId) {
    final current = VideoPlayerPlatform.instance;
    return current is LiveDurationVideoPlatform &&
        current._indefinitePlayers.contains(playerId);
  }

  /// Whether the media at [url] is currently played by a player that reported
  /// an indefinite length — the same record as [isIndefinite], keyed by what
  /// the app actually knows about its media.
  ///
  /// `false` when the decorator is not installed, or before that media's
  /// `initialized` event has been seen.
  static bool isIndefiniteUrl(String url) {
    final current = VideoPlayerPlatform.instance;
    return current is LiveDurationVideoPlatform &&
        current._indefiniteUrls.contains(url);
  }

  /// Rewrites the duration of an indefinite `initialized` event and records the
  /// player as indefinite. Every other event passes through untouched.
  ///
  /// A `null` duration is NOT rewritten: video_player reads
  /// `isInitialized: event.duration != null`, so inventing a length there would
  /// declare a player that never loaded ready to render.
  VideoEvent _sanitize(int playerId, VideoEvent event) {
    if (event.eventType != VideoEventType.initialized) return event;
    if (event.duration == null) return event;
    final url = _urlOf[playerId];
    if (!isIndefiniteReportedDuration(event.duration)) {
      _indefinitePlayers.remove(playerId);
      if (url != null) _indefiniteUrls.remove(url);
      return event;
    }
    _indefinitePlayers.add(playerId);
    if (url != null) _indefiniteUrls.add(url);
    return VideoEvent(
      eventType: event.eventType,
      duration: kIndefiniteDurationStandIn,
      size: event.size,
      rotationCorrection: event.rotationCorrection,
      buffered: event.buffered,
      isPlaying: event.isPlaying,
    );
  }

  // ── Pure forwarding below ────────────────────────────────────────────────

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _delegate
      .videoEventsFor(playerId)
      .map((event) => _sanitize(playerId, event));

  @override
  Future<void> init() => _delegate.init();

  @override
  Future<void> dispose(int playerId) {
    _indefinitePlayers.remove(playerId);
    final url = _urlOf.remove(playerId);
    // Another player may still be on the same URL (the preload-then-swap
    // quality change overlaps two controllers) — only forget the URL once none
    // of them is left.
    if (url != null && !_urlOf.containsValue(url)) _indefiniteUrls.remove(url);
    return _delegate.dispose(playerId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    // ignore: deprecated_member_use
    final id = await _delegate.create(dataSource);
    if (id != null) _record(id, dataSource);
    return id;
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = await _delegate.createWithOptions(options);
    if (id != null) _record(id, options.dataSource);
    return id;
  }

  void _record(int playerId, DataSource dataSource) {
    final url = dataSource.uri ?? dataSource.asset;
    if (url != null) _urlOf[playerId] = url;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) =>
      _delegate.setLooping(playerId, looping);

  @override
  Future<void> play(int playerId) => _delegate.play(playerId);

  @override
  Future<void> pause(int playerId) => _delegate.pause(playerId);

  @override
  Future<void> setVolume(int playerId, double volume) =>
      _delegate.setVolume(playerId, volume);

  @override
  Future<void> seekTo(int playerId, Duration position) =>
      _delegate.seekTo(playerId, position);

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) =>
      _delegate.setPlaybackSpeed(playerId, speed);

  @override
  Future<Duration> getPosition(int playerId) => _delegate.getPosition(playerId);

  @override
  // ignore: deprecated_member_use
  Widget buildView(int playerId) => _delegate.buildView(playerId);

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      _delegate.buildViewWithOptions(options);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) =>
      _delegate.setMixWithOthers(mixWithOthers);

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) =>
      _delegate.setAllowBackgroundPlayback(allowBackgroundPlayback);

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) =>
      _delegate.setPreventsDisplaySleepDuringVideoPlayback(
        playerId,
        preventsDisplaySleepDuringVideoPlayback,
      );

  @override
  Future<void> setWebOptions(int playerId, VideoPlayerWebOptions options) =>
      _delegate.setWebOptions(playerId, options);

  @override
  Future<List<VideoAudioTrack>> getAudioTracks(int playerId) =>
      _delegate.getAudioTracks(playerId);

  @override
  Future<void> selectAudioTrack(int playerId, String trackId) =>
      _delegate.selectAudioTrack(playerId, trackId);

  @override
  bool isAudioTrackSupportAvailable() =>
      _delegate.isAudioTrackSupportAvailable();

  @override
  Future<List<VideoTrack>> getVideoTracks(int playerId) =>
      _delegate.getVideoTracks(playerId);

  @override
  Future<void> selectVideoTrack(int playerId, VideoTrack? track) =>
      _delegate.selectVideoTrack(playerId, track);

  @override
  bool isVideoTrackSupportAvailable() =>
      _delegate.isVideoTrackSupportAvailable();
}
