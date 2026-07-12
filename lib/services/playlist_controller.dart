import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../appAudioHandler.dart';
import '../services/analytics_service.dart';
import '../types/Station.dart';
import '../types/playlist_item.dart';
import 'playlist_reconciler.dart';
import 'playlist_sync_service.dart';
import 'video_playback_service.dart';

/// Orchestrates sequential playback of a "playlist" station's items.
///
/// Owns the sequencing brain (which item plays next, when to auto-advance, how
/// to react to a live reconcile) while delegating actual playback to
/// [AppAudioHandler]:
///   - `audio` items  → just_audio (VOD) via [AppAudioHandler.playPlaylistAudioItem]
///   - `video` items  → media_kit video mode (or audio-only when backgrounded /
///                       car / cast) via [AppAudioHandler.playPlaylistVideoItem]
///   - `youtube` / `youtube_playlist` items → the engine does NOT own a
///                       player; it emits the item on [youtubeRequest] and the
///                       UI renders an inline iframe, reporting back via
///                       [notifyYoutubeItemEnded] / [notifyYoutubeItemError] /
///                       [notifyYoutubePlaying]. play/pause/seek are routed
///                       through the handler + [youtubeShouldPlay]/[youtubeSeek]
///                       so playbackState reflects the iframe. In car/cast these
///                       are skipped; in background they pause.
///   - `unknown` items → an unrecognized future kind. Unplayable — the engine
///                       auto-advances past it (never handed to a player).
///
/// Pure decisions live in [PlaylistReconciler] / [PlaylistNavigator] so they can
/// be unit-tested without any real player.
///
/// ## Contract for the UI layer
/// - Observe [items], [currentIndex], [currentItem], [position], [duration],
///   [isVideoContent], [isYoutubeContent] to render the player + track list.
/// - For video items, embed `Video(controller: videoService.controller)`.
/// - For youtube items, observe [youtubeRequest] (the item to load) and
///   [youtubeShouldPlay] (pause the iframe when false), and call
///   [notifyYoutubeItemEnded]/[notifyYoutubeItemError]/[notifyYoutubePosition].
/// - Call [startLiveSync]/[stopLiveSync] on playlist-page visibility.
/// - Drive playback with [playItemAt], [skipToNext], [skipToPrevious], [seek],
///   [pause], [resume].
class PlaylistController {
  PlaylistController({
    required VideoPlaybackService videoService,
    required PlaylistSyncService syncService,
  })  : _video = videoService,
        _sync = syncService;

  final VideoPlaybackService _video;
  final PlaylistSyncService _sync;

  // Looked up lazily — the handler registers after this controller.
  AppAudioHandler get _handler => GetIt.instance<AppAudioHandler>();

  // ── Public state (UI subscribes) ───────────────────────────────────────
  final BehaviorSubject<List<PlaylistItem>> items =
      BehaviorSubject<List<PlaylistItem>>.seeded(const []);
  final BehaviorSubject<int> currentIndex = BehaviorSubject<int>.seeded(-1);
  final BehaviorSubject<PlaylistItem?> currentItem =
      BehaviorSubject<PlaylistItem?>.seeded(null);
  final BehaviorSubject<Duration> position =
      BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration?> duration =
      BehaviorSubject<Duration?>.seeded(null);

  /// True when the current item plays through media_kit video mode (UI shows
  /// the `Video` widget). False for audio/youtube items or audio-only fallback.
  final BehaviorSubject<bool> isVideoContent =
      BehaviorSubject<bool>.seeded(false);

  /// True when the current item is a YouTube entry (UI shows the iframe).
  final BehaviorSubject<bool> isYoutubeContent =
      BehaviorSubject<bool>.seeded(false);

  /// The YouTube item the UI must render inline, or null when none is active.
  final BehaviorSubject<PlaylistItem?> youtubeRequest =
      BehaviorSubject<PlaylistItem?>.seeded(null);

  /// Whether the inline YouTube player should be playing. This is the single
  /// play/pause command channel for youtube items: toggled false while the app
  /// is backgrounded (YouTube can't play backgrounded) and by the handler when
  /// the user pauses/resumes from the mini player / lock screen. The iframe
  /// binds its play/pause to it.
  final BehaviorSubject<bool> youtubeShouldPlay =
      BehaviorSubject<bool>.seeded(true);

  /// Seek requests for the inline YouTube player (single video only). The
  /// iframe subscribes and calls `controller.seekTo`.
  final PublishSubject<Duration> youtubeSeek = PublishSubject<Duration>();

  /// Ids of items that failed to play (dead url, decode error, unavailable
  /// YouTube video). The track list dims these rows and shows an error icon.
  /// An id is cleared when that item later plays successfully.
  final BehaviorSubject<Set<int>> failedItemIds =
      BehaviorSubject<Set<int>>.seeded(const {});

  /// Brief, user-facing messages for the UI to surface as a toast — e.g. when
  /// an unavailable item is auto-skipped. The full-cycle-failure case instead
  /// surfaces the handler's connection-error layout (see [_onItemError]).
  final PublishSubject<String> transientMessages = PublishSubject<String>();

  /// Consecutive item failures since the last item that actually played. When
  /// this reaches the item count, an entire cycle has failed, so we stop with
  /// the connection-error surface instead of skipping forever. Reset the moment
  /// any item makes real playback progress (see [_markPlaybackProgress]).
  int _consecutiveFailures = 0;

  Station? _activeStation;

  /// The playlist station currently being played, or null when inactive.
  Station? get activeStation => _activeStation;
  bool get isActive => _activeStation != null;
  int get itemCount => items.value.length;

  /// The video service backing `video`-type items — the UI embeds
  /// `Video(controller: playlistController.videoService.controller)`.
  VideoPlaybackService get videoService => _video;

  bool _wired = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ── Lifecycle wiring (once, on first playlist) ──────────────────────────
  void _ensureWired() {
    if (_wired) return;
    _wired = true;

    // Auto-advance / error handling for the just_audio (audio item) backend.
    _handler.onPlaylistItemCompleted = _onItemCompleted;
    _handler.onPlaylistItemError = (e) => _onItemError(e);

    // Video item completion (media_kit). Errors are NOT advanced here: the
    // handler's video-fallback watchdog first hands the SAME content to the
    // audio-only pipeline (video error → audio), and only if THAT also fails
    // does `playPlaylistAudioItem` route back through [onPlaylistItemError] to
    // advance. This keeps a single "try audio before skipping" policy.
    _subs.add(_video.completedStream.listen((completed) {
      if (!completed) return;
      if (currentItem.value?.type != PlaylistItemType.video) return;
      if (!_handler.isVideoModeActive) return; // audio-only handles its own EOS
      _onItemCompleted();
    }));

    // Position / duration: forward whichever backend is active for the item.
    _subs.add(_video.positionStream.listen((p) {
      if (_handler.isVideoModeActive) {
        position.add(p);
        if (p > _progressThreshold) _markPlaybackProgress();
      }
    }));
    _subs.add(_video.durationStream.listen((d) {
      if (_handler.isVideoModeActive) duration.add(d);
    }));
    _subs.add(_handler.player.positionStream.listen((p) {
      if (!_handler.isVideoModeActive && !isYoutubeContent.value) {
        position.add(p);
        if (p > _progressThreshold) _markPlaybackProgress();
      }
    }));
    _subs.add(_handler.player.durationStream.listen((d) {
      if (!_handler.isVideoModeActive && !isYoutubeContent.value) {
        // just_audio emits null/zero briefly on each new source; keep the
        // item's seeded duration (set in playItemAt) so the audio VOD seek bar
        // stays enabled instead of flickering to "unknown".
        if (d != null && d > Duration.zero) duration.add(d);
      }
    }));

    // Live reconcile from the 5s poll.
    _subs.add(_sync.updates.listen(_onSyncUpdate));
  }

  // ── Start / stop ─────────────────────────────────────────────────────────

  /// Starts playing [station]'s playlist from [startIndex] (or the first
  /// playable item after it). Enters playlist mode on the handler and begins
  /// the live 5s sync.
  Future<void> startPlaylist(Station station, {int startIndex = 0}) async {
    _log('startPlaylist(${station.slug}, startIndex=$startIndex)');
    _ensureWired();
    _activeStation = station;
    _consecutiveFailures = 0;
    failedItemIds.add(const {});
    _handler.enterPlaylistMode();
    items.add(station.playlistItems);

    final firstPlayable = PlaylistNavigator.nextPlayableIndex(
      items: items.value,
      fromIndex: startIndex - 1,
      skipYoutube: _skipYoutube,
      loop: false,
      direction: 1,
    );
    // Begin live sync so item add/remove is reflected within 5s. The UI may
    // additionally toggle this on page visibility.
    startLiveSync();
    if (firstPlayable < 0) {
      // Nothing playable — e.g. a youtube-only playlist opened on a car/cast
      // route (youtube items can't run there). Stop gracefully (no crash, no
      // skip loop; the bounded navigator already guarantees termination) and
      // leave a telemetry breadcrumb, mirroring the item-error path.
      _log('startPlaylist: no playable item (skipYoutube=$_skipYoutube)');
      AnalyticsService.instance.capture('playlist_no_playable_item', {
        'station_slug': station.slug,
        'item_count': items.value.length,
        'skip_youtube': _skipYoutube,
        'is_car_connected': _handler.isCarConnected,
        'is_casting': _handler.isCasting,
      });
      await _stopPlayback();
      return;
    }
    await playItemAt(firstPlayable);
  }

  /// Stops playlist playback entirely and leaves playlist mode.
  Future<void> stop() async {
    _log('stop');
    stopLiveSync();
    _activeStation = null;
    _consecutiveFailures = 0;
    failedItemIds.add(const {});
    await _stopPlayback();
    _handler.exitPlaylistMode();
    items.add(const []);
    currentIndex.add(-1);
    currentItem.add(null);
    isVideoContent.add(false);
    isYoutubeContent.add(false);
    youtubeRequest.add(null);
    duration.add(null);
    position.add(Duration.zero);
  }

  Future<void> _stopPlayback() async {
    youtubeRequest.add(null);
    await _handler.stopPlaylistPlayback();
  }

  // ── Item playback ─────────────────────────────────────────────────────────

  /// Plays the item at [index], routing by media kind. Carries an optional
  /// [startPosition] (used across background handoffs).
  Future<void> playItemAt(int index, {Duration? startPosition}) async {
    final list = items.value;
    if (index < 0 || index >= list.length) return;
    final item = list[index];
    _log('playItemAt($index): ${item.type.name} ${item.title}');

    // New item — give video a fresh attempt (drops the "Doar audio" chip and
    // any fallen-back-url guard for the previous item).
    _handler.resetVideoFallback();

    currentIndex.add(index);
    currentItem.add(item);
    duration.add(item.durationSeconds != null
        ? Duration(seconds: item.durationSeconds!)
        : null);

    switch (item.type) {
      case PlaylistItemType.audio:
        isVideoContent.add(false);
        isYoutubeContent.add(false);
        youtubeRequest.add(null);
        _handler.updatePlaylistMediaItem(item, index: index, count: list.length);
        await _handler.playPlaylistAudioItem(item.url,
            startPosition: startPosition);
        break;
      case PlaylistItemType.video:
        isYoutubeContent.add(false);
        youtubeRequest.add(null);
        _handler.updatePlaylistMediaItem(item, index: index, count: list.length);
        await _handler.playPlaylistVideoItem(item.url,
            live: false, startPosition: startPosition);
        isVideoContent.add(_handler.isVideoModeActive);
        break;
      case PlaylistItemType.youtube:
      case PlaylistItemType.youtubePlaylist:
        isVideoContent.add(false);
        isYoutubeContent.add(true);
        _handler.updatePlaylistMediaItem(item, index: index, count: list.length);
        // No engine-owned player — stop local backends and delegate to the UI.
        await _handler.stopPlaylistPlayback();
        final shouldPlay = _handler.isForeground;
        youtubeShouldPlay.add(shouldPlay);
        // Broadcast a synthetic playing state so the mini player / notification
        // reflect + control the iframe (one source of truth via the handler).
        _handler.setPlaylistYoutubeActive(true, playing: shouldPlay);
        youtubeRequest.add(item);
        break;
      case PlaylistItemType.unknown:
        // Unrecognized future kind — unplayable. Auto-advance past it.
        _log('playItemAt: unknown item type → skip');
        isVideoContent.add(false);
        isYoutubeContent.add(false);
        youtubeRequest.add(null);
        _handler.setPlaylistYoutubeActive(false);
        await _handler.stopPlaylistPlayback();
        unawaited(_advance(direction: 1));
        break;
    }
  }

  /// Advances to the next playable item (lock-screen / steering-wheel "next").
  Future<void> skipToNext() => _advance(direction: 1);

  /// Goes to the previous playable item.
  Future<void> skipToPrevious() => _advance(direction: -1);

  Future<void> _advance({required int direction}) async {
    final next = PlaylistNavigator.nextPlayableIndex(
      items: items.value,
      fromIndex: currentIndex.value,
      skipYoutube: _skipYoutube,
      loop: true,
      direction: direction,
    );
    if (next < 0) {
      _log('advance($direction): nothing playable, stopping');
      await _stopPlayback();
      return;
    }
    await playItemAt(next);
  }

  /// Seeks the current item.
  ///
  /// A single `youtube` video seeks its inline iframe via [youtubeSeek]. A
  /// `youtube_playlist` has no meaningful item-level timeline, so seeking is a
  /// no-op there. Everything else (audio / video VOD) seeks the routed player.
  Future<void> seek(Duration to) async {
    final item = currentItem.value;
    if (item == null) return;
    if (item.type == PlaylistItemType.youtube) {
      youtubeSeek.add(to);
      position.add(to); // optimistic — the iframe confirms shortly
      return;
    }
    if (item.type.isYoutube) return; // youtube_playlist: item-level seek N/A
    await _handler.seek(to);
  }

  Future<void> pause() async => _handler.pause();
  Future<void> resume() async => _handler.play();

  /// Resumes the inline YouTube player. Routed here by [AppAudioHandler.play]
  /// so the mini player / lock screen and the in-player button share one path.
  void resumeYoutube() {
    if (!(currentItem.value?.type.isYoutube ?? false)) return;
    youtubeShouldPlay.add(true);
    _handler.updateYoutubePlaybackState(playing: true);
  }

  /// Pauses the inline YouTube player. Routed here by [AppAudioHandler.pause].
  void pauseYoutube() {
    if (!(currentItem.value?.type.isYoutube ?? false)) return;
    youtubeShouldPlay.add(false);
    _handler.updateYoutubePlaybackState(playing: false);
  }

  // ── Auto-advance / error ────────────────────────────────────────────────

  /// A position past which we treat the current item as genuinely playing (not
  /// a false-start), used to clear its failed flag and reset the loop guard.
  static const Duration _progressThreshold = Duration(milliseconds: 1200);

  void _onItemCompleted() {
    _log('item completed → advance');
    // Reaching the end is unambiguous success — clear the guard and any stale
    // failed flag on this item.
    _markPlaybackProgress();
    unawaited(_advance(direction: 1));
  }

  void _onItemError(Object error) {
    final item = currentItem.value;
    _log('item error ($error) on ${item?.id} → advance (fail #${_consecutiveFailures + 1})');
    AnalyticsService.instance.capture('playlist_item_error', {
      'station_slug': _activeStation?.slug,
      'item_id': item?.id,
      'item_type': item?.type.name,
      'item_url': item?.url,
      'error': error.toString(),
    });
    if (item != null) _markItemFailed(item.id);
    _consecutiveFailures++;

    // Loop guard: if every item has failed once in a row, stop instead of
    // skipping forever. The bounded navigator already guarantees a single
    // advance terminates; this bounds the *cascade* of advances across items.
    final count = itemCount;
    if (count > 0 && _consecutiveFailures >= count) {
      _log('all $count item(s) failed in a row → stopping with error surface');
      AnalyticsService.instance.capture('playlist_all_items_failed', {
        'station_slug': _activeStation?.slug,
        'item_count': count,
      });
      _surfacePlaylistError();
      unawaited(_stopPlayback());
      return;
    }

    // Intermediate failure — tell the user we're moving on, then advance. The
    // UI pairs this with an "Element indisponibil" title for the full sentence
    // "Element indisponibil — se trece la următorul".
    transientMessages.add('Se trece la următorul');
    unawaited(_advance(direction: 1));
  }

  /// Emits the handler's connection-error so the app shows its standard error
  /// layout when a whole playlist cycle fails.
  void _surfacePlaylistError() {
    _handler.connectionError.add(ConnectionError(
      stationName: _activeStation?.title ?? 'Listă de redare',
      reason: ConnectionErrorReason.unknown,
      details: 'Niciun element din listă nu a putut fi redat',
    ));
  }

  /// Records that the current item is playing (real progress or completion):
  /// resets the failure loop guard and clears this item's failed flag so its
  /// row un-dims.
  void _markPlaybackProgress() {
    if (_consecutiveFailures != 0) _consecutiveFailures = 0;
    final id = currentItem.value?.id;
    if (id != null) _clearItemFailed(id);
  }

  void _markItemFailed(int id) {
    final next = Set<int>.of(failedItemIds.value)..add(id);
    failedItemIds.add(next);
  }

  void _clearItemFailed(int id) {
    if (!failedItemIds.value.contains(id)) return;
    final next = Set<int>.of(failedItemIds.value)..remove(id);
    failedItemIds.add(next);
  }

  /// Hands the current (failing) VIDEO item off to audio-only playback. Called
  /// by [AppAudioHandler] when its video-fallback watchdog trips; the handler
  /// has already surfaced the "Doar audio" chip and recorded the fallen-back
  /// url. This is NOT a failure — the content still plays (audio), so the loop
  /// guard and failed flag are untouched.
  Future<void> fallbackCurrentVideoToAudio({Duration? startPosition}) async {
    final item = currentItem.value;
    if (item == null || item.type != PlaylistItemType.video) return;
    _log('fallbackCurrentVideoToAudio: ${item.id}');
    isVideoContent.add(false);
    isYoutubeContent.add(false);
    await _handler.playPlaylistAudioItem(item.url, startPosition: startPosition);
  }

  // ── YouTube contract (UI → engine) ───────────────────────────────────────

  /// Whether a callback from an inline YouTube player is still relevant, i.e.
  /// the current item is a youtube item AND the reporting player belongs to it.
  ///
  /// [reportingItemId] is the id of the item the calling iframe was rendering.
  /// The full player keeps two iframes briefly mounted during the 250ms
  /// crossfade between youtube items, so the OUTGOING iframe can fire a late
  /// error/ended after we've already advanced. Without this id check the stale
  /// event would drive a SECOND advance — skipping the freshly-started youtube
  /// row (the reported "jumps two items / skips the iframe item" bug). A null id
  /// keeps the legacy behavior (relevant whenever the current item is youtube).
  bool _isCurrentYoutube(int? reportingItemId) {
    final current = currentItem.value;
    if (current == null || !current.type.isYoutube) return false;
    if (reportingItemId != null && reportingItemId != current.id) {
      _log('ignoring stale youtube callback from item $reportingItemId '
          '(current is ${current.id})');
      return false;
    }
    return true;
  }

  /// The UI calls this when the inline YouTube video (or the WHOLE playlist for
  /// a youtube_playlist item) ends → auto-advance. Inner-video transitions
  /// within a youtube_playlist must NOT trigger this. [itemId] scopes the event
  /// to the reporting iframe (see [_isCurrentYoutube]).
  void notifyYoutubeItemEnded({int? itemId}) {
    if (!_isCurrentYoutube(itemId)) return;
    _log('youtube ended → advance');
    _markPlaybackProgress(); // a played-through item is a success
    unawaited(_advance(direction: 1));
  }

  /// The UI calls this when the inline YouTube player errors → advance.
  void notifyYoutubeItemError({int? itemId}) {
    if (!_isCurrentYoutube(itemId)) return;
    _onItemError('youtube_player_error');
  }

  /// Optional position report from the inline YouTube player, for the scrubber
  /// and the lock-screen/notification.
  void notifyYoutubePosition(Duration pos, Duration dur, {int? itemId}) {
    if (!_isCurrentYoutube(itemId)) return;
    position.add(pos);
    if (dur > Duration.zero) duration.add(dur);
    if (pos > _progressThreshold) _markPlaybackProgress();
    _handler.updateYoutubePlaybackState(position: pos);
  }

  /// The inline YouTube player reports its real playing/paused state → mirror
  /// it into the handler so the mini player, notification and lock screen stay
  /// in sync (the single source of truth is [AppAudioHandler.playbackState]).
  void notifyYoutubePlaying(bool playing, {int? itemId}) {
    if (!_isCurrentYoutube(itemId)) return;
    // A YouTube item that reaches the playing state has loaded successfully —
    // clear its failed flag and reset the loop guard.
    if (playing) _markPlaybackProgress();
    _handler.updateYoutubePlaybackState(playing: playing);
  }

  // ── Live sync ────────────────────────────────────────────────────────────

  /// Starts the 5s live playlist poll for the active station. Called on
  /// playlist-page visibility by the UI (also auto-started by [startPlaylist]).
  void startLiveSync() {
    final slug = _activeStation?.slug;
    if (slug == null) return;
    _sync.startSync(slug);
  }

  /// Stops the live poll (playlist page hidden).
  void stopLiveSync() => _sync.stopSync();

  void _onSyncUpdate(List<PlaylistItem> incoming) {
    if (!isActive) return;
    final result = PlaylistReconciler.reconcile(
      current: items.value,
      currentIndex: currentIndex.value,
      incoming: incoming,
    );
    items.add(result.items);

    if (result.shouldStop) {
      _log('reconcile: current gone, no survivor → stop');
      unawaited(stop());
      return;
    }
    if (result.currentItemRemoved && result.currentIndex >= 0) {
      _log('reconcile: current removed → advance to ${result.currentIndex}');
      currentIndex.add(result.currentIndex);
      unawaited(playItemAt(result.currentIndex));
      return;
    }
    // Current item survived — never restart it; just keep index aligned.
    if (result.currentIndex >= 0) {
      currentIndex.add(result.currentIndex);
      currentItem.add(result.items[result.currentIndex]);
    }
  }

  // ── App lifecycle (from AppAudioHandler.onAppLifecycleChanged) ────────────

  void onAppLifecycleChanged(AppLifecycleState state) {
    final item = currentItem.value;
    final backgrounded = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;
    if (backgrounded) {
      _sync.pause();
      if (item == null) return;
      if (item.type.isYoutube) {
        youtubeShouldPlay.add(false); // YouTube can't play backgrounded
        _handler.updateYoutubePlaybackState(playing: false);
        return;
      }
      if (item.type == PlaylistItemType.video && _handler.isVideoModeActive) {
        // Hand off video → audio-only (playPlaylistVideoItem re-decides now
        // that isForeground is false), carrying the current position.
        final pos = _video.position;
        unawaited(_handler.playPlaylistVideoItem(item.url,
            live: false, startPosition: pos));
      }
    } else if (state == AppLifecycleState.resumed) {
      _sync.resume();
      if (item == null) return;
      if (item.type.isYoutube) {
        youtubeShouldPlay.add(true);
        _handler.updateYoutubePlaybackState(playing: true);
        return;
      }
      if (item.type == PlaylistItemType.video && !_handler.isVideoModeActive) {
        // Hand back audio-only → video mode, carrying position. If this item
        // previously fell back to audio, the handler keeps it audio-only, so
        // reflect whatever mode it actually settled into.
        final pos = _handler.player.position;
        () async {
          await _handler.playPlaylistVideoItem(item.url,
              live: false, startPosition: pos);
          isVideoContent.add(_handler.isVideoModeActive);
        }();
      }
    }
  }

  /// Called by the handler when a car/Cast route connects mid-video-mode:
  /// re-plays the current video item, which now routes to audio-only because
  /// [_skipYoutube]/route state changed. Carries the current video position.
  Future<void> handleRouteChangeToAudio() async {
    final item = currentItem.value;
    if (item == null) return;
    if (item.type == PlaylistItemType.video && _handler.isVideoModeActive) {
      final pos = _video.position;
      await _handler.playPlaylistVideoItem(item.url,
          live: false, startPosition: pos);
      isVideoContent.add(_handler.isVideoModeActive);
    } else if (item.type.isYoutube) {
      // A youtube item can't play in car/cast — skip to the next playable.
      await _advance(direction: 1);
    }
  }

  bool get _skipYoutube =>
      _handler.isCarConnected || _handler.isCasting;

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    items.close();
    currentIndex.close();
    currentItem.close();
    position.close();
    duration.close();
    isVideoContent.close();
    isYoutubeContent.close();
    youtubeRequest.close();
    youtubeShouldPlay.close();
    youtubeSeek.close();
    failedItemIds.close();
    transientMessages.close();
  }

  void _log(String message) => debugPrint('PlaylistController: $message');
}
