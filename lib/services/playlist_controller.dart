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
///   - `youtube` items → the engine does NOT own a player; it emits the item on
///                       [youtubeRequest] and the UI renders an inline iframe,
///                       reporting back via [notifyYoutubeItemEnded] /
///                       [notifyYoutubeItemError]. In car/cast youtube items are
///                       skipped automatically; in background they pause.
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

  /// Whether the inline YouTube player should be playing. Set to false while
  /// the app is backgrounded (YouTube can't play backgrounded). The UI binds
  /// its iframe play/pause to this.
  final BehaviorSubject<bool> youtubeShouldPlay =
      BehaviorSubject<bool>.seeded(true);

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

    // Video item completion / error (media_kit).
    _subs.add(_video.completedStream.listen((completed) {
      if (!completed) return;
      if (currentItem.value?.type != PlaylistItemType.video) return;
      if (!_handler.isVideoModeActive) return; // audio-only handles its own EOS
      _onItemCompleted();
    }));
    _subs.add(_video.errorStream.listen((e) {
      if (currentItem.value?.type != PlaylistItemType.video) return;
      if (!_handler.isVideoModeActive) return;
      _onItemError(e);
    }));

    // Position / duration: forward whichever backend is active for the item.
    _subs.add(_video.positionStream.listen((p) {
      if (_handler.isVideoModeActive) position.add(p);
    }));
    _subs.add(_video.durationStream.listen((d) {
      if (_handler.isVideoModeActive) duration.add(d);
    }));
    _subs.add(_handler.player.positionStream.listen((p) {
      if (!_handler.isVideoModeActive && !isYoutubeContent.value) position.add(p);
    }));
    _subs.add(_handler.player.durationStream.listen((d) {
      if (!_handler.isVideoModeActive && !isYoutubeContent.value) {
        duration.add(d);
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
      _log('startPlaylist: no playable item');
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
        isVideoContent.add(false);
        isYoutubeContent.add(true);
        _handler.updatePlaylistMediaItem(item, index: index, count: list.length);
        // No engine-owned player — stop local backends and delegate to the UI.
        await _handler.stopPlaylistPlayback();
        youtubeShouldPlay.add(_handler.isForeground);
        youtubeRequest.add(item);
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

  /// Seeks the current VOD item.
  Future<void> seek(Duration to) async {
    final item = currentItem.value;
    if (item == null || item.type == PlaylistItemType.youtube) return;
    await _handler.seek(to);
  }

  Future<void> pause() async => _handler.pause();
  Future<void> resume() async => _handler.play();

  // ── Auto-advance / error ────────────────────────────────────────────────

  void _onItemCompleted() {
    _log('item completed → advance');
    unawaited(_advance(direction: 1));
  }

  void _onItemError(Object error) {
    _log('item error ($error) → advance');
    final item = currentItem.value;
    AnalyticsService.instance.capture('playlist_item_error', {
      'station_slug': _activeStation?.slug,
      'item_id': item?.id,
      'item_type': item?.type.name,
      'item_url': item?.url,
      'error': error.toString(),
    });
    unawaited(_advance(direction: 1));
  }

  // ── YouTube contract (UI → engine) ───────────────────────────────────────

  /// The UI calls this when the inline YouTube video ends → auto-advance.
  void notifyYoutubeItemEnded() {
    if (currentItem.value?.type != PlaylistItemType.youtube) return;
    _log('youtube ended → advance');
    unawaited(_advance(direction: 1));
  }

  /// The UI calls this when the inline YouTube player errors → advance.
  void notifyYoutubeItemError() {
    if (currentItem.value?.type != PlaylistItemType.youtube) return;
    _onItemError('youtube_player_error');
  }

  /// Optional position report from the inline YouTube player, for the scrubber.
  void notifyYoutubePosition(Duration pos, Duration dur) {
    if (currentItem.value?.type != PlaylistItemType.youtube) return;
    position.add(pos);
    if (dur > Duration.zero) duration.add(dur);
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
      if (item.type == PlaylistItemType.youtube) {
        youtubeShouldPlay.add(false); // YouTube can't play backgrounded
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
      if (item.type == PlaylistItemType.youtube) {
        youtubeShouldPlay.add(true);
        return;
      }
      if (item.type == PlaylistItemType.video && !_handler.isVideoModeActive) {
        // Hand back audio-only → video mode, carrying position.
        final pos = _handler.player.position;
        unawaited(_handler.playPlaylistVideoItem(item.url,
            live: false, startPosition: pos));
        isVideoContent.add(true);
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
    } else if (item.type == PlaylistItemType.youtube) {
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
  }

  void _log(String message) => debugPrint('PlaylistController: $message');
}
