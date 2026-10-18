import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpException, SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/audible_now_playing_resolver.dart';
import 'package:radio_crestin/services/audible_song_policy.dart';
import 'package:radio_crestin/services/car_play_layout.dart';
import 'package:radio_crestin/services/failure_streak.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/services/now_playing_sanitizer.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/private_stations_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/services/station_sort_service.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/hls_timeline.dart' show SongBoundaryHint;
import 'package:radio_crestin/services/image_cache_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Why a live sync was requested. Listed in priority order: of the reasons
/// queued while a sync is in flight, the lowest index decides the work.
///
/// Invariant: each reason's work is a superset of every later reason's work
/// (a full refresh includes the live fetch), so promoting or coalescing
/// reasons never loses work. Side work (private stations, the listening
/// timeline, audible checks) runs if any queued reason asks for it. The
/// time-shifted song of the playing station is resolved outside this queue
/// ([StationDataService.refreshMetadataNow]).
enum SyncReason {
  /// Initial bootstrap on app start.
  startup,

  /// App returned from background — distrust everything, refetch.
  appResumed,

  /// Pull-to-refresh, back to the TV browse list, CarPlay connect.
  manualRefresh,

  /// The network came back after an outage: catch the list up now rather
  /// than at the next tick. A live diff, as failed fetches left the cursor
  /// behind — or a full refresh when the catalog never arrived (a first
  /// launch offline shows the bundled list) or is over 10 minutes old.
  networkRestored,

  /// User picked a station to play: a live diff, so its song and listeners
  /// are the newest. Not the catalog: the songs would wait for its ~200 KB.
  stationPlayed,

  /// A live stream announced a new song (ICY tag, Android TV playlist
  /// METADATA-CHANGED): fetch the live list now.
  liveMetadataChanged,

  /// The listening delay changed (seek offset, car, cast): move the
  /// listening timeline now.
  listeningDelayChanged,

  /// 60s wall-clock tick — keep the visible station list reasonably fresh.
  periodic,
}

class StationDataService {
  final GraphQLClient graphqlClient;

  /// Fetches + persists the device-allowlisted ("private") station list. Owns
  /// the fetch policy state machine; this service parses its raw output into
  /// [Station]s and merges them into the public catalog.
  final PrivateStationsService _privateStationsService;

  /// REST client for `/stations-metadata` and the history endpoint.
  final http.Client _http;
  final bool _ownsHttpClient;

  /// How long an unused API connection stays open: past the 60 s tick,
  /// with room for a late timer, so each tick reuses the last one's
  /// connections. dart:io's default (15 s) had every tick open new ones
  /// (up to three), with their TLS handshakes on the UI isolate. The API's
  /// edge (Cloudflare) keeps idle connections open longer than that.
  static const _httpIdleTimeout = Duration(seconds: 90);

  /// A client for the API whose connections last from one tick to the
  /// next. main() shares it with the station list's REST link, so that
  /// request reuses them too.
  static http.Client createHttpClient() =>
      IOClient(HttpClient()..idleTimeout = _httpIdleTimeout);

  /// Wall clock and delay, injectable so tests control time.
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;

  // ---------------------------------------------------------------------------
  // Sync engine state
  // ---------------------------------------------------------------------------

  /// Fixed cadence for the periodic safety-net poll. Audio events drive
  /// the playing station's now-playing; this tick keeps the list itself
  /// fresh for stations the user can see but isn't playing.
  static const _periodicInterval = Duration(seconds: 60);

  /// 10-min full refresh window. Inserted into the next sync (regardless
  /// of reason) once elapsed, to pull GraphQL stations + reviews drift.
  static const _fullRefreshInterval = Duration(minutes: 10);

  /// How far each diff (live or listening) re-reads behind its cursor. Rows
  /// are dated when the song started but become visible up to ~38 s later
  /// (ingestion lag); without the overlap a diff issued in between skips
  /// them for good. Merges are idempotent, so re-delivered stations cost
  /// nothing.
  static const _diffOverlap = Duration(seconds: 60);

  /// How far past the listening timestamp the lookahead reads: the next
  /// periodic tick (60 s) plus the timestamp's 10 s floor, so a station
  /// picked any time before that tick finds the song it plays.
  static const _listeningLookahead = Duration(seconds: 70);

  Timer? _periodicTimer;

  /// Per timeline, the diff URL of its last successful fetch. The edge
  /// caches each URL, so the same request again gets the same copy back:
  /// nothing new to merge. A full fetch of the timeline clears it.
  final Map<String, String> _lastDiffUrl = {};

  /// Network restore and mobile-data/WiFi switches (see [_watchNetwork]).
  final List<StreamSubscription<bool>> _networkSubscriptions = [];

  /// Mutex over the sync pipeline. All paths funnel through `enqueueSync`,
  /// so a single in-flight call is enough — overlapping triggers coalesce
  /// into [_pendingReasons].
  bool _isSyncing = false;

  /// Reasons queued while a sync is in flight, drained together on
  /// completion of the current sync. Empty means nothing pending.
  Set<SyncReason> _pendingReasons = <SyncReason>{};

  /// Completes when the pending reasons have run, so a coalesced caller
  /// awaits the work it asked for instead of returning early.
  Completer<void>? _pendingDone;

  /// Live-timeline cursor (Unix seconds, 10s-rounded): the `timestamp` of
  /// the last live fetch that succeeded. Never advanced by a failed fetch.
  int _liveCursor = 0;

  /// When the last full refresh (GraphQL + REST) was performed.
  DateTime? _lastFullRefreshTime;

  /// When the GraphQL catalog last arrived. Unlike [_lastFullRefreshTime],
  /// a full refresh that failed (offline) does not count.
  DateTime? _lastCatalogAt;

  // ---------------------------------------------------------------------------
  // Audible (time-shifted) now-playing of the playing station
  // ---------------------------------------------------------------------------

  /// With no successful aligned resolution for this long, the periodic tick
  /// re-anchors the playing station (safety net for a missed boundary).
  static const _audibleSafetyNet = Duration(minutes: 5);

  /// An ICY title change means the live row started within this window.
  static const _icyLookback = Duration(seconds: 30);

  /// Gaps between live re-fetches while a signalled change is not in the
  /// live list yet; each lands in a newer 10 s bucket, so a new edge key.
  static const _liveFollowUpDelays = [
    Duration(seconds: 10),
    Duration(seconds: 10),
    Duration(seconds: 20),
  ];

  late final AudibleNowPlayingResolver _resolver;

  /// The song the listener hears on time-shifted HLS (the overlay). Applied
  /// to the published station only while it is the playing one; never
  /// written into [_publicStations], which stay live.
  AudibleNowPlaying? _audible;

  /// When an aligned song was last applied or an anchor last started: the
  /// safety-net clock, so a station is re-anchored at most every
  /// [_audibleSafetyNet] when nothing else resolves it.
  DateTime? _lastAudibleCheckAt;

  /// Bumped by every aligned request and by [onAlignedPlaybackEnded]: a
  /// result is applied only if no newer request or end came meanwhile.
  int _audibleRequest = 0;

  /// Bumped to cancel a scheduled anchor re-check.
  int _audibleRecheck = 0;

  /// Bumped to cancel an in-flight live follow-up (latest signal wins).
  int _liveFollowUp = 0;

  // ---------------------------------------------------------------------------
  // Listening timeline: the list at now − the listening delay
  // ---------------------------------------------------------------------------

  /// Each public station's `now_playing` at now − the listening delay. A
  /// station heard through time-shifted HLS shows it instead of its live
  /// row, so its card shows what tapping it plays, and keeps showing that
  /// once the player leaves it. Empty while the delay is zero.
  Map<int, Map<String, dynamic>> _listeningNowPlaying = {};

  /// Listening-timeline cursor (Unix seconds, 10s-rounded), like
  /// [_liveCursor]; 0 while the timeline is not fetched.
  int _listeningCursor = 0;

  /// Each public station's `now_playing` at [_listeningLookahead] after the
  /// listening timestamp ([_listeningAheadCursor]): the song a station picked
  /// before the next sync can already play. Fetched only while that instant
  /// is final on the server (see [_looksAhead]); empty otherwise.
  Map<int, Map<String, dynamic>> _listeningAhead = {};

  /// Lookahead cursor (Unix seconds, 10s-rounded); 0 while not fetched.
  int _listeningAheadCursor = 0;

  /// Stations already rebuilt with their listening row, so a publish only
  /// rebuilds those whose live data or listening row changed.
  final Map<int, ({Station live, Map<String, dynamic> row, Station shown})>
      _listeningShown = {};

  // ---------------------------------------------------------------------------
  // Audio sync hooks (set by AppAudioHandler after init)
  // ---------------------------------------------------------------------------

  /// True while the local player has a live HLS stream loaded (playing,
  /// paused or buffering): the playing station's now-playing must then come
  /// from the audible timeline, never the live one.
  bool Function()? isTimeShiftedHlsActive;

  /// Server wall-clock instant of the audio the listener hears (or would
  /// hear on resume). Frozen while paused/buffering. Null when not
  /// time-shifted HLS, or while the timeline is still anchoring (an anchored
  /// refresh follows automatically).
  DateTime? Function()? getAudibleInstant;

  /// Id of the station the player is on (playing, paused or loading), or
  /// null.
  int? Function()? getPlayingStationId;

  /// True while the player has a stream loaded that plays live (a direct
  /// stream, e.g. after an HLS failover): the playing station then shows
  /// its live row, not the listening timeline.
  bool Function()? isLiveStreamActive;

  /// How far behind live a station tapped now is heard: the seek offset
  /// plus the player's hold-back on time-shifted HLS, zero while casting.
  /// Null (tests, before wiring) keeps the whole list live.
  Duration Function()? getListeningDelay;

  /// When true, show LIVE now-playing metadata for the playing station instead
  /// of the HLS-buffered (delayed) metadata. Set on Android TV: the buffered
  /// audio lag is acceptable on a 10-foot UI, and the live song is what users
  /// expect to see. Mobile leaves this false (delayed/aligned metadata).
  bool preferLiveMetadata = false;

  // ---------------------------------------------------------------------------
  // Streams
  // ---------------------------------------------------------------------------

  final BehaviorSubject<List<Station>> stations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<Station>> filteredStations = BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> favoriteStationSlugs = BehaviorSubject.seeded([]);

  /// Slugs of the stations the listener hid, oldest first.
  ///
  /// A hidden station leaves every list: the home page, its favorites, the
  /// search, CarPlay and Android Auto. [stations] still holds it, so it
  /// keeps playing, and showing its song, while it is the current station.
  final BehaviorSubject<List<String>> hiddenStationSlugs =
      BehaviorSubject.seeded([]);
  final BehaviorSubject<List<Query$GetStations$station_groups>> stationGroups =
      BehaviorSubject.seeded(<Query$GetStations$station_groups>[]);
  final BehaviorSubject<Query$GetStations$station_groups?> selectedStationGroup =
      BehaviorSubject.seeded(null);

  /// Whether the playing station was picked from a favorites list.
  ///
  /// While true, next/previous only cycle through the favorites, once there
  /// are at least two of them; a sole favorite steps through the list it
  /// sits in. Persisted so the context survives restarts: autoplay and car
  /// autoplay resume the last station without picking from a list again.
  bool get startedFromFavorites =>
      GetIt.instance<SharedPreferences>().getBool(_startedFromFavoritesKey) ??
      false;

  set startedFromFavorites(bool value) {
    unawaited(GetIt.instance<SharedPreferences>()
        .setBool(_startedFromFavoritesKey, value));
  }

  /// Slug of the car category (station group) the playing station was
  /// picked from; null when it came from any other list.
  ///
  /// While set, next/previous only cycle through that group's stations, in
  /// the order the car lists them; a one-station group steps through the
  /// whole catalog. Persisted like [startedFromFavorites].
  String? get startedFromGroup =>
      GetIt.instance<SharedPreferences>().getString(_startedFromGroupKey);

  set startedFromGroup(String? slug) {
    final prefs = GetIt.instance<SharedPreferences>();
    unawaited(slug == null
        ? prefs.remove(_startedFromGroupKey)
        : prefs.setString(_startedFromGroupKey, slug));
  }

  /// Cached sort order (list of slugs) for the user-chosen (non-recommended)
  /// sort options. Keeps the order stable during the session. Only
  /// invalidated when the user picks a different sort option.
  List<String>? _cachedSortOrder;
  StationSortOption? _cachedSortOption;

  /// Frozen recommended ("Pentru tine") order as a slug list, computed
  /// exactly once per session the first time a non-empty station set
  /// arrives. Playing stations, favorite toggles, listener changes and the
  /// 60s metadata poll never reshuffle it — only genuinely new stations are
  /// appended at the end and removed ones drop out. This is THE source of
  /// truth for recommended order across phone, TV, desktop, CarPlay and
  /// Android Auto.
  List<String>? _frozenRecommendedOrder;

  /// The full station set in the frozen recommended order, carrying live
  /// metadata, re-emitted on every [stations] change. Screens (TV/desktop)
  /// subscribe to this instead of re-sorting in `build()`, so card positions
  /// stay put and the D-pad focus tree stays stable.
  final BehaviorSubject<List<Station>> orderedStations =
      BehaviorSubject.seeded(<Station>[]);

  /// Emits whenever the sort cache is invalidated, so listeners (CarPlay,
  /// Android Auto) can rebuild their station lists with the new order.
  final PublishSubject<void> sortOrderChanged = PublishSubject<void>();

  // Constants
  static const _favoriteStationsKey = 'favoriteStationSlugs';
  static const _favoriteOrderKeptKey = 'favorite_order_kept';
  static const _hiddenStationsKey = 'hiddenStationSlugs';
  static const _startedFromFavoritesKey = 'started_from_favorites';
  static const _startedFromGroupKey = 'started_from_group';
  static const _cachedStationsKey = 'cached_stations_data';
  static const _minStationsForCache = 10;

  /// Minimum gap between rewrites of an unchanged catalog cache.
  static const _stationsCacheMinInterval = Duration(minutes: 30);

  static const _fieldTypenames = {
    'stations': 'StationType',
    'station_streams': 'StationStreamType',
    'playlist_items': 'StationPlaylistItemType',
    'posts': 'PostType',
    'uptime': 'StationUptimeType',
    'now_playing': 'StationNowPlayingType',
    'song': 'SongType',
    'artist': 'ArtistType',
    'reviews': 'ReviewType',
    'station_groups': 'StationGroupType',
    'station_to_station_groups': 'StationToStationGroupType',
  };

  /// Fingerprint and time of the last persisted catalog. Null until the
  /// first write of the session, which therefore always happens.
  String? _lastCachedStationsKey;
  DateTime? _lastCachedStationsAt;

  /// [httpClient], [clock] and [wait] default to the real network, wall
  /// clock and timers; tests inject a fake backend and controlled time.
  /// main() passes a [createHttpClient] it shares. The default client,
  /// which [dispose] closes, follows `http.runWithClient`, as tests use.
  StationDataService({
    required this.graphqlClient,
    PrivateStationsService? privateStationsService,
    http.Client? httpClient,
    DateTime Function()? clock,
    Future<void> Function(Duration)? wait,
  })  : _privateStationsService =
            privateStationsService ?? PrivateStationsService(),
        _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _now = clock ?? DateTime.now,
        _wait = wait ?? Future<void>.delayed {
    _resolver = AudibleNowPlayingResolver(
      fetchHistory: (slug, window) =>
          SongHistoryService.fetchPage(slug, window, client: _http),
      now: _now,
      wait: _wait,
    );
    // Wire the frozen-order stream up front (not in initialize) so
    // orderedStations tracks `stations` from the very first emission.
    _initOrderedStationsStream();
  }

  // ---------------------------------------------------------------------------
  // Public / private catalog split
  //
  // `stations` is the MERGED catalog. It is rebuilt from two internal sources
  // so a public-only metadata refresh can never clobber or drop private
  // stations, and a private refresh can never disturb the frozen public order.
  // ---------------------------------------------------------------------------

  /// Latest public station list, live data only (the only source the live
  /// `/stations-metadata` fetch updates). The listening timeline and the
  /// playing station's time-shifted song are overlays applied at publish
  /// time, never stored here.
  List<Station> _publicStations = <Station>[];

  /// Latest private station list, in the backend-provided order. Their
  /// now_playing/uptime/listeners come ONLY from the private payload — the
  /// public metadata endpoint never carries them.
  List<Station> _privateStations = <Station>[];

  void _log(String message) {
    debugPrint("StationDataService: $message");
  }

  // The station list (GraphQL) and the live metadata (REST) fetch every
  // minute or so: their failures are logged when they start and when they
  // end, not each time.
  final _catalogFailures = FailureStreak();
  final _metadataFailures = FailureStreak();

  void _noteFetchFailure(FailureStreak streak, String source, Object error) {
    if (!streak.fail(_now())) return;
    final text = '$error';
    AnalyticsService.instance.logWarning('station data fetch failing', {
      'source': source,
      'error': text.length > 200 ? text.substring(0, 200) : text,
    });
  }

  void _noteFetchSuccess(FailureStreak streak, String source) {
    final ended = streak.succeed(_now());
    if (ended == null) return;
    AnalyticsService.instance.log('station data fetch recovered', {
      'source': source,
      'failures': ended.failures,
      'failed_for_s': ended.duration.inSeconds,
    });
  }

  // ---------------------------------------------------------------------------
  // Public API — every refresh path funnels through enqueueSync.
  // ---------------------------------------------------------------------------

  Future<void> initialize() async {
    // Before the first list is built, so a hidden station never shows.
    _initHiddenStationSlugs();
    _initFilteredStationsStream();
    await _initFavoriteStationSlugs();
    // Once the catalog is known: from the cache, or only from the network.
    stations.stream.firstWhere((all) => all.isNotEmpty).then(
          (_) => _keepShownFavoriteOrder(),
          // Disposed before any station was listed.
          onError: (Object _) {},
        );
    _watchNetwork();
    await _bootstrap();
  }

  /// Reacts to connectivity changes. Each stream replays its current value
  /// on listen, which is skipped: only real changes matter here.
  void _watchNetwork() {
    final network = NetworkService.instance;
    _networkSubscriptions
      // Only while syncing is on: with polling paused in the background,
      // the resume refresh catches the list up instead.
      ..add(network.isOffline.stream
          .skip(1)
          .where((offline) => !offline && _periodicTimer != null)
          .listen((_) => unawaited(enqueueSync(SyncReason.networkRestored))))
      // The list picks song art or station logos by the network type when
      // it builds (data saving on mobile data). Rebuild it on a switch, or
      // a WiFi network that came up after mobile data keeps the logos
      // until the next change in the data.
      ..add(network.isOnMobileData.stream.skip(1).listen((_) {
        if (stations.value.isNotEmpty) _publishMerged(force: true);
      }));
  }

  /// Single entry point for every live refresh. Overlapping triggers coalesce
  /// and run once the current sync finishes; the returned future completes
  /// when the work this call asked for has run.
  Future<void> enqueueSync(SyncReason reason) {
    if (_isSyncing) {
      if (_pendingReasons.add(reason)) {
        _log("queue: $reason (pending after current sync)");
      }
      return (_pendingDone ??= Completer<void>()).future;
    }
    return _drain({reason});
  }

  Future<void> _drain(Set<SyncReason> first) async {
    _isSyncing = true;
    try {
      await _runSync(first);
      while (_pendingReasons.isNotEmpty) {
        final reasons = _pendingReasons;
        final done = _pendingDone;
        _pendingReasons = <SyncReason>{};
        _pendingDone = null;
        try {
          await _runSync(reasons);
        } finally {
          if (done != null && !done.isCompleted) done.complete();
        }
      }
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _runSync(Set<SyncReason> reasons) async {
    try {
      await _executeSync(reasons);
    } catch (e) {
      _log("sync failed: $e");
    }
  }

  /// Pull-to-refresh, TV browse, CarPlay connect: a full live refresh.
  Future<void> refreshStations() => enqueueSync(SyncReason.manualRefresh);

  /// The audio announced (or the audible timeline reached) a song change.
  ///
  /// [boundary]: the song boundary the audible instant just reached (null
  /// for the anchored refresh and for non-HLS triggers). [hint]: the new
  /// song's attributes when the playlist carried them (backend B14).
  ///
  /// On time-shifted HLS of a public station this resolves the song the
  /// listener hears (a change at [boundary], or the song at the audible
  /// instant after a (re)anchor) into the overlay; everywhere else it
  /// follows the live list until the signalled change shows up.
  Future<void> refreshMetadataNow({
    DateTime? boundary,
    SongBoundaryHint? hint,
  }) {
    _log('refreshMetadataNow(boundary: ${boundary?.toIso8601String()}'
        '${hint == null ? '' : ', hint: ${hint.songId} ${hint.title}'})');
    final id = getPlayingStationId?.call();
    if (id == null) return enqueueSync(SyncReason.liveMetadataChanged);
    if (_alignable(id)) {
      return boundary == null
          ? _resolveAnchor(id)
          : _resolveChange(id, boundary, hint);
    }
    final timeShifted = isTimeShiftedHlsActive?.call() ?? false;
    if (timeShifted && boundary == null) {
      // An anchored refresh (TV or a private station): no change was
      // signalled, so one live fetch is all there is to do.
      return enqueueSync(SyncReason.liveMetadataChanged);
    }
    return _followLiveChange(id,
        changedAtOrAfter:
            boundary?.subtract(AudibleSongPolicy.changeRowLead) ??
                _now().subtract(_icyLookback));
  }

  /// The player left time-shifted HLS playback for good (station switch,
  /// stop, error, non-HLS load, cast start): cancel every aligned request
  /// and show the station's live song again.
  void onAlignedPlaybackEnded() {
    _audibleRequest++;
    _audibleRecheck++;
    _resolver.cancelAll();
    _lastAudibleCheckAt = null;
    if (_audible == null) return;
    _audible = null;
    _log('audible: overlay cleared (aligned playback ended)');
    _publishMerged();
  }

  /// The listening delay changed: move the listening timeline now instead
  /// of on the next tick. Before the first load the startup sync reads it.
  void onListeningDelayChanged() {
    if (stations.value.isEmpty) return;
    unawaited(enqueueSync(SyncReason.listeningDelayChanged));
  }

  /// The "recently played" cutoff for [stationId]: the audible instant for
  /// the time-shifted station (its last resolved instant while the clock is
  /// unknown, e.g. paused past the disconnect), now − the listening delay
  /// for a station shown on the listening timeline, now for every other one.
  DateTime playedCutoffFor(int stationId) {
    final audible = getAudibleInstant?.call();
    final playing = getPlayingStationId?.call() == stationId;
    if (playing && audible != null && _alignable(stationId)) return audible;
    final overlay = _audible;
    if (overlay != null && overlay.stationId == stationId) {
      return audible ?? overlay.heardAt;
    }
    final station = _publicStationById(stationId);
    if (station != null && _listeningRowFor(station) != null) {
      return _now().subtract(_listeningDelay);
    }
    return _now();
  }

  /// Called when the app resumes from background.
  Future<void> onAppResumed() async {
    _log("App resumed from background");
    resumePeriodic();
    await enqueueSync(SyncReason.appResumed);
  }

  /// Called by AppAudioHandler when a new station starts playing.
  Future<void> onStationPlayed() => enqueueSync(SyncReason.stationPlayed);

  /// Forces a private-stations refresh outside the periodic cadence, honoring
  /// the session gate. The periodic tick and full refreshes already drive this
  /// automatically; exposed for explicit triggers and tests.
  Future<void> refreshPrivateStations() => _syncPrivateStations();

  void pausePeriodic() {
    _log("Pausing periodic sync");
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  void resumePeriodic() {
    if (_periodicTimer != null) return;
    _log("Resuming periodic sync (every ${_periodicInterval.inSeconds}s)");
    _periodicTimer = Timer.periodic(
      _periodicInterval,
      (_) => enqueueSync(SyncReason.periodic),
    );
  }

  /// Stops all background work but keeps the service usable: the periodic
  /// tick, a live follow-up and every aligned request.
  ///
  /// For the app's task being removed (swiped away). The process, and with
  /// it this singleton, can survive that: audio_service keeps the Flutter
  /// engine cached, so a relaunch reuses this instance and the app-resume
  /// path ([onAppResumed] → [resumePeriodic]) restarts it. [dispose] would
  /// end the service for good.
  void suspend() {
    pausePeriodic();
    _liveFollowUp++;
    onAlignedPlaybackEnded();
  }

  /// Final teardown: the service is never used again.
  void dispose() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    for (final subscription in _networkSubscriptions) {
      subscription.cancel();
    }
    _networkSubscriptions.clear();
    _resolver.cancelAll();
    _audibleRequest++;
    _audibleRecheck++;
    _liveFollowUp++;
    final pending = _pendingDone;
    _pendingDone = null;
    _pendingReasons = <SyncReason>{};
    if (pending != null && !pending.isCompleted) pending.complete();
    if (_ownsHttpClient) _http.close();
  }

  // Backward-compatible aliases — older call sites used these names.
  void pausePolling() => pausePeriodic();
  void resumePolling() => resumePeriodic();

  // ---------------------------------------------------------------------------
  // Sync engine internals
  // ---------------------------------------------------------------------------

  /// One sync iteration for every reason queued together. The highest-priority
  /// reason picks the public work (its work covers the others'); a reason's
  /// side work (private stations, listening timeline, audible checks) runs if
  /// any reason asks for it. Promotes to a full refresh when the 10-min
  /// window has elapsed.
  Future<void> _executeSync(Set<SyncReason> reasons) async {
    final lead = reasons.reduce((a, b) => a.index <= b.index ? a : b);
    // A resume is a fresh chance for private stations: reopen the gate an
    // authoritative-empty / not-deployed response may have closed this session.
    if (reasons.contains(SyncReason.appResumed)) {
      _privateStationsService.reopenSessionGate();
    }

    final privateFuture =
        reasons.any(_shouldFetchPrivate) ? _syncPrivateStations() : null;

    final fullDue = _lastFullRefreshTime == null ||
        _now().difference(_lastFullRefreshTime!) >= _fullRefreshInterval;
    final lastCatalogAt = _lastCatalogAt;
    final catalogDue = reasons.contains(SyncReason.networkRestored) &&
        (lastCatalogAt == null ||
            _now().difference(lastCatalogAt) >= _fullRefreshInterval);
    final isFullReason = lead.index <= SyncReason.manualRefresh.index;
    final full = isFullReason || fullDue || catalogDue;
    final listeningFuture = reasons.any(_shouldSyncListening)
        ? _syncListeningTimeline(full: full)
        : null;

    if (full) {
      await _doFullRefresh(lead, becausePromoted: !isFullReason);
    } else {
      await _doLiveDiff();
    }
    if (privateFuture != null) await privateFuture;
    // Change-gated: a no-op when the public publish already carried it.
    if (listeningFuture != null && await listeningFuture) _publishMerged();

    if (reasons.contains(SyncReason.periodic)) _checkAudibleOnTick();
    if (reasons.contains(SyncReason.appResumed)) {
      unawaited(_revalidateAudible());
    }
  }

  /// Private stations are fetched on startup, on resume, and on the 60s
  /// periodic tick (which piggybacks the same timer). Other reasons
  /// (stationPlayed, manual refresh, live metadata change) leave the private
  /// list untouched — nothing about them changes the allowlist.
  bool _shouldFetchPrivate(SyncReason reason) =>
      reason == SyncReason.startup ||
      reason == SyncReason.appResumed ||
      reason == SyncReason.periodic;

  /// Every reason but a live stream's song change moves the listening
  /// timeline: that signal is about the live list, and its follow-ups would
  /// only repeat the same delayed fetch.
  bool _shouldSyncListening(SyncReason reason) =>
      reason != SyncReason.liveMetadataChanged;

  /// Full refresh: GraphQL stations + live metadata, merged in one shot. The
  /// live cursor moves only when the metadata fetch succeeded.
  Future<void> _doFullRefresh(SyncReason reason, {required bool becausePromoted}) async {
    final promoted =
        becausePromoted ? ' (promoted: 10-min window or catalog due)' : '';
    _log("full refresh: $reason$promoted");
    // NOTE: deliberately does NOT invalidate the sort cache. The recommended
    // order is frozen per-session (see [_frozenRecommendedOrder]); the other
    // sort options stay stable within a session too. Only an explicit
    // user-initiated sort-option change calls invalidateSortCache().
    try {
      final liveTs = _roundedNow();
      final metadataApplied = await _fetchStationsWithMetadata(liveTs);
      _lastFullRefreshTime = _now();
      if (metadataApplied) _liveCursor = liveTs;
      _preCacheStationThumbnails();
    } catch (e) {
      _log("full refresh failed: $e");
    }
  }

  /// Live diff: every station that changed since the cursor (minus the
  /// overlap), at the live timestamp. A failed fetch leaves the cursor, so
  /// the next diff covers the gap.
  Future<void> _doLiveDiff() async {
    if (stations.value.isEmpty) return;
    final liveTs = _roundedNow();
    final canDiff = _liveCursor > 0 && _liveCursor <= liveTs;
    PerformanceMonitor.startOperation('periodic_sync');
    final live = await _fetchMetadata(
      liveTs,
      changesFromTimestamp:
          canDiff ? _liveCursor - _diffOverlap.inSeconds : null,
    );
    PerformanceMonitor.endOperation('periodic_sync');
    if (live == null) return;
    _liveCursor = liveTs;
    _applyLiveMetadata(live);
  }

  /// Merges live metadata into [_publicStations]. A station absent from
  /// [live] is unchanged (a diff only lists the stations that changed).
  void _applyLiveMetadata(Map<int, Map<String, dynamic>> live) {
    _publicStations = [
      for (final station in _publicStations)
        live[station.id] == null
            ? station
            : _mergeStationWithMetadata(station, live[station.id]!),
    ];
    if (!_publishMerged()) return;
    _log("merge: stations updated");
    if (SeekModeManager.isUnstableConnection) {
      _preCacheSongThumbnails(_publicStations);
    }
  }

  int _roundedNow() => _roundedEpoch(_now());

  /// Unix seconds of [t], floored to 10 s: the shared cache key bucket.
  static int _roundedEpoch(DateTime t) =>
      t.millisecondsSinceEpoch ~/ 10000 * 10;

  // ---------------------------------------------------------------------------
  // Listening timeline: what tapping a station plays
  // ---------------------------------------------------------------------------

  /// The listening delay, zero on the TV live-metadata mode.
  Duration get _listeningDelay => preferLiveMetadata
      ? Duration.zero
      : getListeningDelay?.call() ?? Duration.zero;

  /// Moves the listening timeline to now − the listening delay, and its
  /// lookahead to [_listeningLookahead] after it while [_looksAhead]: each a
  /// diff from its own cursor like the live diff, or the whole list when
  /// [full], without a cursor, or when the delay grew (the instant moved
  /// back). A zero delay forgets both. Returns whether their rows changed.
  Future<bool> _syncListeningTimeline({required bool full}) async {
    final delay = _listeningDelay;
    if (delay <= Duration.zero) {
      if (_listeningCursor == 0 && _listeningAheadCursor == 0) return false;
      _listeningNowPlaying = {};
      _listeningShown.clear();
      _listeningCursor = 0;
      _forgetListeningAhead();
      return true;
    }
    final ts = _roundedEpoch(_now().subtract(delay));
    final ahead = ts + _listeningLookahead.inSeconds;
    final looksAhead = _looksAhead(delay);
    final listeningFuture = _fetchTimelineRows(ts,
        cursor: _listeningCursor,
        rows: _listeningNowPlaying,
        full: full,
        timeline: 'listening');
    final aheadFuture = looksAhead
        ? _fetchTimelineRows(ahead,
            cursor: _listeningAheadCursor,
            rows: _listeningAhead,
            full: full,
            timeline: 'listening ahead')
        : null;
    final listening = await listeningFuture;
    final aheadRows = await aheadFuture;
    var changed = false;
    if (listening != null) {
      _listeningNowPlaying = listening;
      _listeningCursor = ts;
      changed = true;
    }
    if (aheadRows != null) {
      _listeningAhead = aheadRows;
      _listeningAheadCursor = ahead;
      changed = true;
    } else if (!looksAhead && _listeningAheadCursor != 0) {
      _forgetListeningAhead();
      changed = true;
    }
    return changed;
  }

  /// Whether the lookahead instant is final on the server, so its rows can
  /// prove the song a picked station plays: it stays at least
  /// [AudibleSongPolicy.ingestionSafety] behind now until the next sync. True
  /// at 5 minutes (306 s), not at 2 (126 s), where the live song proves the
  /// same within that window ([_liveSongReachedListeners]).
  bool _looksAhead(Duration delay) =>
      delay >= _listeningLookahead + AudibleSongPolicy.ingestionSafety;

  void _forgetListeningAhead() {
    _listeningAhead = {};
    _listeningAheadCursor = 0;
  }

  /// [rows] moved to [ts]: the stations a diff from [cursor] lists merged
  /// into them, or the whole list when it can't be a diff. Null when the
  /// fetch failed.
  Future<Map<int, Map<String, dynamic>>?> _fetchTimelineRows(
    int ts, {
    required int cursor,
    required Map<int, Map<String, dynamic>> rows,
    required bool full,
    required String timeline,
  }) async {
    final canDiff = !full && cursor > 0 && cursor <= ts;
    final fetched = await _fetchMetadata(
      ts,
      changesFromTimestamp: canDiff ? cursor - _diffOverlap.inSeconds : null,
      timeline: timeline,
    );
    if (fetched == null) return null;
    final next = canDiff ? Map.of(rows) : <int, Map<String, dynamic>>{};
    fetched.forEach((id, metadata) {
      final nowPlaying = metadata['now_playing'];
      if (nowPlaying is Map<String, dynamic>) {
        next[id] = nowPlaying;
      } else {
        next.remove(id);
      }
    });
    return next;
  }

  /// [station]'s row on the listening timeline when that is what the
  /// listener hears on it, or would on tapping it: a radio station whose
  /// preferred stream is time-shifted HLS. Null shows the live row: a direct
  /// stream, or the playing station on a live stream (an HLS failover).
  Map<String, dynamic>? _listeningRowFor(Station station) {
    final row = _listeningNowPlaying[station.id];
    if (row == null ||
        station.stationType != StationMediaType.radio ||
        !station.prefersHls) {
      return null;
    }
    final playsLive = getPlayingStationId?.call() == station.id &&
        (isLiveStreamActive?.call() ?? false);
    return playsLive ? null : row;
  }

  /// Every station heard on the listening timeline with its listening row
  /// in place of the live one. Only `now_playing` changes; listeners and
  /// uptime stay live.
  List<Station> _withListeningTimeline(List<Station> merged) {
    if (_listeningNowPlaying.isEmpty) return merged;
    return [for (final station in merged) _onListeningTimeline(station)];
  }

  Station _onListeningTimeline(Station station) {
    final listening = _listeningRowFor(station);
    if (listening == null || _liveSongReachedListeners(station)) {
      return station;
    }
    final row = _aheadSongReachedListeners(station) ?? listening;
    final memo = _listeningShown[station.id];
    if (memo != null &&
        identical(memo.live, station) &&
        identical(memo.row, row)) {
      return memo.shown;
    }
    final shown = _rebuild(station, (json) => _withNowPlaying(json, row));
    _listeningShown[station.id] = (live: station, row: row, shown: shown);
    return shown;
  }

  /// Whether [station]'s live song already started at now − the listening
  /// delay, with a live list recent enough to prove that no later song did
  /// ([AudibleSongPolicy.liveProvesAudible]): tapping the station plays it.
  /// The listening row can still hold the song before: it is as old as its
  /// last fetch, at a timestamp floored to 10 s.
  bool _liveSongReachedListeners(Station station) {
    final row = NowPlayingRow.fromNowPlayingJson(
        station.rawStationData.now_playing?.toJson());
    return row != null &&
        AudibleSongPolicy.liveProvesAudible(
          live: row,
          audible: _now().subtract(_listeningDelay),
          liveCursor: _liveCursor,
        );
  }

  /// [station]'s lookahead row when its song started after the listening
  /// timestamp and by now − the listening delay: tapping the station plays
  /// it, while the listening row, as old as its last fetch, still holds the
  /// song before. Null otherwise.
  Map<String, dynamic>? _aheadSongReachedListeners(Station station) {
    final row = _listeningAhead[station.id];
    final ahead = NowPlayingRow.fromNowPlayingJson(row);
    if (ahead == null) return null;
    final startedAt = ahead.startedAt.millisecondsSinceEpoch;
    final audible = _now().subtract(_listeningDelay).millisecondsSinceEpoch;
    return startedAt > _listeningCursor * 1000 && startedAt <= audible
        ? row
        : null;
  }

  /// [station] as the list shows it now. Songs are placed on the listening
  /// timeline when the list is published, and a live song can reach the
  /// listeners between two syncs (see [_liveSongReachedListeners]), so this
  /// republishes the list if that moved a song: a station picked now shows
  /// the song it plays.
  Station shownNow(Station station) {
    _publishMerged();
    return stations.value.firstWhere(
      (shown) => shown.id == station.id,
      orElse: () => station,
    );
  }

  // ---------------------------------------------------------------------------
  // Audible overlay: the song the listener hears on time-shifted HLS
  // ---------------------------------------------------------------------------

  /// Time-shifted HLS on a public station, and not the TV live-metadata mode.
  /// Private stations are unknown to the public history API.
  bool _alignable(int stationId) =>
      !preferLiveMetadata &&
      (isTimeShiftedHlsActive?.call() ?? false) &&
      _publicStationById(stationId) != null;

  /// (Re)anchor: the song audible at the audible instant. A null instant
  /// (still anchoring) is a no-op; the timeline calls again once anchored.
  /// An unsettled answer gets one re-check ([allowRecheck]), never a chain:
  /// in instant mode the re-check's own answer is unsettled again.
  Future<void> _resolveAnchor(int stationId, {bool allowRecheck = true}) async {
    final audible = getAudibleInstant?.call();
    final station = _publicStationById(stationId);
    if (audible == null || station == null) return;
    _forgetOtherStation(stationId);
    _lastAudibleCheckAt = _now();
    final request = ++_audibleRequest;
    final result = await _resolver.resolveAnchor(
      stationId: stationId,
      slug: station.slug,
      audible: audible,
      live: _liveRow(stationId),
      heard: _audible,
      liveCursor: _liveCursor,
    );
    if (result == null || request != _audibleRequest) return;
    _applyAudible(result);
    if (allowRecheck && !result.settled) _scheduleAudibleRecheck(audible);
  }

  /// Change: the audible instant reached [boundary].
  Future<void> _resolveChange(
    int stationId,
    DateTime boundary,
    SongBoundaryHint? hint,
  ) async {
    final station = _publicStationById(stationId);
    if (station == null) return;
    _forgetOtherStation(stationId);
    final request = ++_audibleRequest;
    final result = await _resolver.resolveChange(
      stationId: stationId,
      slug: station.slug,
      boundary: boundary,
      hint: hint,
      live: _liveRow(stationId),
      songBefore: _audible?.row.songId,
    );
    if (result == null || request != _audibleRequest) return;
    _applyAudible(result);
  }

  /// The overlay of a previous station never seeds a new one.
  void _forgetOtherStation(int stationId) {
    if (_audible?.stationId != stationId) _audible = null;
  }

  /// Applies [result] when its station is still the playing one (a late
  /// result for a station the user left is dropped). No monotonic guard: a
  /// re-anchor further back must be able to show an older song.
  void _applyAudible(AudibleNowPlaying result) {
    if (result.stationId != getPlayingStationId?.call()) {
      _log('audible: dropped a result for station ${result.stationId}');
      return;
    }
    final previousSongId = _audible?.row.songId;
    _audible = result;
    _lastAudibleCheckAt = _now();
    _log('audible: ${result.source.name} song ${result.row.songId} '
        'started ${result.row.startedAt.toIso8601String()} '
        '(heard ${result.heardAt.toIso8601String()})');
    if (result.row.songId != previousSongId) _logSongChanged(result);
    _publishMerged();
  }

  /// The song shown as heard changed: what it is, where it came from and
  /// when it started, for "the wrong song is shown" reports.
  static void _logSongChanged(AudibleNowPlaying result) {
    final song = result.row.nowPlaying['song'];
    final artist = song is Map<String, dynamic> ? song['artist'] : null;
    AnalyticsService.instance.logDebug('song changed', {
      'station_id': result.stationId,
      'song_id': result.row.songId,
      'song': song is Map<String, dynamic> ? song['name'] : null,
      'artist': artist is Map<String, dynamic> ? artist['name'] : null,
      'source': result.source.name,
      'started_at': result.row.startedAt.toIso8601String(),
      'heard_at': result.heardAt.toIso8601String(),
    });
  }

  /// An anchor resolved before ingestion settled may miss a row that started
  /// just before the instant (its boundary was dropped as already heard):
  /// re-anchor once after the ingestion window.
  void _scheduleAudibleRecheck(DateTime audible) {
    final recheck = ++_audibleRecheck;
    final due = audible
        .add(AudibleSongPolicy.ingestionSafety)
        .difference(_now());
    unawaited(_wait(due.isNegative ? Duration.zero : due).then((_) {
      if (recheck != _audibleRecheck) return;
      unawaited(_revalidateAudible(allowRecheck: false));
    }));
  }

  /// Safety net on the periodic tick, after the live diff: a live list that
  /// proves a different audible song means a boundary was missed; with
  /// nothing resolved for [_audibleSafetyNet], re-anchor. Also covers a
  /// station without an audible song yet (a failed first anchor, or a
  /// platform whose clock never anchors, such as Windows/Linux), which
  /// would otherwise show the live song until the next boundary. Skipped
  /// while a request is in flight, so it never cancels a change that is
  /// still retrying.
  void _checkAudibleOnTick() {
    final id = getPlayingStationId?.call();
    final audible = getAudibleInstant?.call();
    if (id == null || audible == null) return;
    if (!_alignable(id) || _resolver.isBusy) return;
    final overlay = _audible?.stationId == id ? _audible : null;
    final live = _liveRow(id);
    if (live != null &&
        live.songId != overlay?.row.songId &&
        AudibleSongPolicy.liveProvesAudible(
            live: live, audible: audible, liveCursor: _liveCursor)) {
      _applyAudible(AudibleNowPlaying(
          stationId: id,
          row: live,
          source: AudibleSource.live,
          heardAt: audible));
      return;
    }
    final last = _lastAudibleCheckAt;
    if (last == null || _now().difference(last) >= _audibleSafetyNet) {
      unawaited(_revalidateAudible());
    }
  }

  /// Re-anchors the playing station unless a request is already in flight.
  Future<void> _revalidateAudible({bool allowRecheck = true}) async {
    final id = getPlayingStationId?.call();
    if (id == null || !_alignable(id) || _resolver.isBusy) return;
    await _resolveAnchor(id, allowRecheck: allowRecheck);
  }

  /// A live stream (ICY, Android TV) signalled a song change: fetch the live
  /// list until the station's row starting at or after [changedAtOrAfter]
  /// shows up (it may not be ingested yet), at most
  /// `_liveFollowUpDelays.length` retries. The latest signal wins.
  Future<void> _followLiveChange(
    int stationId, {
    required DateTime changedAtOrAfter,
  }) async {
    final followUp = ++_liveFollowUp;
    for (var attempt = 0;; attempt++) {
      await enqueueSync(SyncReason.liveMetadataChanged);
      if (followUp != _liveFollowUp) return;
      if (_publicStationById(stationId) == null) return;
      final live = _liveRow(stationId);
      if (live != null && !live.startedAt.isBefore(changedAtOrAfter)) return;
      if (attempt == _liveFollowUpDelays.length) return;
      await _wait(_liveFollowUpDelays[attempt]);
      if (followUp != _liveFollowUp) return;
    }
  }

  /// The station's raw live row (pre-overlay, pre-sanitizer), so timing is
  /// never lost.
  NowPlayingRow? _liveRow(int stationId) => NowPlayingRow.fromNowPlayingJson(
      _publicStationById(stationId)?.rawStationData.now_playing?.toJson());

  Station? _publicStationById(int stationId) {
    for (final station in _publicStations) {
      if (station.id == stationId) return station;
    }
    return null;
  }

  /// The playing station with the audible song in place of its live (or
  /// listening) one. Only `now_playing` changes; listeners and uptime stay
  /// live.
  List<Station> _withAudibleOverlay(List<Station> merged) {
    final overlay = _audible;
    if (overlay == null ||
        preferLiveMetadata ||
        overlay.stationId != getPlayingStationId?.call()) {
      return merged;
    }
    return [
      for (final station in merged)
        station.id == overlay.stationId
            ? _rebuild(station,
                (json) => _withNowPlaying(json, overlay.row.nowPlaying))
            : station,
    ];
  }

  /// Hides stale or placeholder now-playing values for display (C12).
  List<Station> _sanitizedForDisplay(List<Station> merged) {
    final now = _now();
    return [
      for (final station in merged) _sanitized(station, now),
    ];
  }

  Station _sanitized(Station station, DateTime now) {
    final nowPlaying = station.rawStationData.now_playing;
    final verdict = NowPlayingSanitizer.verdict(
      stationTitle: station.rawStationData.title,
      startedAt: DateTime.tryParse(nowPlaying?.timestamp ?? ''),
      songName: nowPlaying?.song?.name,
      artistName: nowPlaying?.song?.artist?.name,
      now: now,
    );
    if (verdict == NowPlayingVerdict.keep) return station;
    return _rebuild(
        station, (json) => NowPlayingSanitizer.apply(json, verdict));
  }

  // ---------------------------------------------------------------------------
  // Merge + publish
  // ---------------------------------------------------------------------------

  /// Ids of private stations that are NOT shadowed by a public station of the
  /// same id (public wins on conflict). This is the set treated as "private"
  /// for pinning and filtering.
  Set<int> get _privateOnlyIds {
    if (_privateStations.isEmpty) return const <int>{};
    final publicIds = _publicStations.map((s) => s.id as int).toSet();
    return _privateStations
        .where((s) => !publicIds.contains(s.id))
        .map((s) => s.id as int)
        .toSet();
  }

  /// Builds the merged catalog: private-only stations (deduped against public
  /// by id, public wins) followed by the public list. Display order is imposed
  /// later by [getSortedStations] / [orderedStations]; this order only affects
  /// change detection.
  List<Station> _mergePublicPrivate() {
    if (_privateStations.isEmpty) return List<Station>.of(_publicStations);
    final publicIds = _publicStations.map((s) => s.id as int).toSet();
    final privateOnly =
        _privateStations.where((s) => !publicIds.contains(s.id));
    return [...privateOnly, ..._publicStations];
  }

  /// Publishes the merged catalog (with the listening timeline, the audible
  /// overlay on top of it and the display sanitizer) to [stations].
  /// Change-gated by default so a no-op refresh doesn't churn downstream
  /// streams; [force] bypasses the gate for structural changes (bootstrap,
  /// full refresh, private list cleared). Returns whether it emitted.
  bool _publishMerged({bool force = false}) {
    final merged = _sanitizedForDisplay(_withAudibleOverlay(
        _withListeningTimeline(_mergePublicPrivate())));
    if (!force && !hasStationsChanged(stations.value, merged)) return false;
    stations.add(merged);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Favorites
  // ---------------------------------------------------------------------------

  /// Adds [station] to the favorites, last or at [index] of
  /// [favoriteStationSlugs] (the place it had before it was hidden), or
  /// removes it.
  Future<void> setStationIsFavorite(
    Station station,
    bool isFavorite, {
    int? index,
  }) async {
    _log("setStationIsFavorite: ${station.slug} $isFavorite");
    if (isFavorite) {
      final current = favoriteStationSlugs.value;
      final at = (index ?? current.length).clamp(0, current.length);
      favoriteStationSlugs.add([...current]..insert(at, station.slug));
    } else {
      favoriteStationSlugs
          .add(favoriteStationSlugs.value.where((slug) => slug != station.slug).toList());
    }
    final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
    await prefs.setString(_favoriteStationsKey, json.encode(favoriteStationSlugs.value));
  }

  Future<void> _initFavoriteStationSlugs() async {
    final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
    final String? favoriteJson = prefs.getString(_favoriteStationsKey);
    if (favoriteJson != null) {
      favoriteStationSlugs.add(List<String>.from(json.decode(favoriteJson)));
    }
  }

  /// The favorites among [source], in the listener's order: the order of
  /// [favoriteStationSlugs], which they can rearrange on the home page.
  List<Station> favoritesIn(Iterable<Station> source) {
    final bySlug = {for (final station in source) station.slug: station};
    return [
      for (final slug in favoriteStationSlugs.value)
        if (bySlug[slug] case final station?) station,
    ];
  }

  /// Puts the favorites in the order of [shown]: the favorites as the
  /// listener sees them, after moving one. Favorites that [shown] leaves
  /// out, e.g. a station the catalog no longer lists, keep their places.
  Future<void> setFavoriteOrder(List<String> shown) async {
    final current = favoriteStationSlugs.value;
    final moving = shown.where(current.contains).toList();
    final movingSet = moving.toSet();
    var next = 0;
    final reordered = [
      for (final slug in current)
        movingSet.contains(slug) ? moving[next++] : slug,
    ];
    if (listEquals(reordered, current)) return;
    _log("setFavoriteOrder: $reordered");
    favoriteStationSlugs.add(reordered);
    final prefs = GetIt.instance<SharedPreferences>();
    await prefs.setString(_favoriteStationsKey, json.encode(reordered));
  }

  /// Saves the order the favorites were shown in before the listener could
  /// arrange them, the first time the catalog is known: the station list's
  /// sort, which the stored list (oldest favorite first) didn't follow.
  /// Without it their favorites would come back in a new order.
  Future<void> _keepShownFavoriteOrder() async {
    final prefs = GetIt.instance<SharedPreferences>();
    if (prefs.getBool(_favoriteOrderKeptKey) ?? false) return;
    final shown = [
      for (final station in getSortedStations(applyGroupFilter: false))
        station.slug as String,
    ];
    if (shown.isEmpty) return;
    await setFavoriteOrder(
        shown.where(favoriteStationSlugs.value.contains).toList());
    await prefs.setBool(_favoriteOrderKeptKey, true);
  }

  // ---------------------------------------------------------------------------
  // Hidden stations
  // ---------------------------------------------------------------------------

  /// Hides [station] from every station list, or shows it again. See
  /// [hiddenStationSlugs].
  Future<void> setStationIsHidden(Station station, bool isHidden) async {
    final hidden = hiddenStationSlugs.value;
    if (hidden.contains(station.slug) == isHidden) return;
    _log("setStationIsHidden: ${station.slug} $isHidden");
    hiddenStationSlugs.add(isHidden
        ? [...hidden, station.slug]
        : hidden.where((slug) => slug != station.slug).toList());
    final prefs = GetIt.instance<SharedPreferences>();
    await prefs.setString(
        _hiddenStationsKey, json.encode(hiddenStationSlugs.value));
  }

  /// The catalog the listener sees: [stations] without the hidden ones.
  List<Station> get visibleStations => _withoutHidden(stations.value);

  /// The hidden stations still in the catalog, the last one hidden first.
  List<Station> get hiddenStations {
    final bySlug = {for (final s in stations.value) s.slug: s};
    return [
      for (final slug in hiddenStationSlugs.value.reversed)
        if (bySlug[slug] case final station?) station,
    ];
  }

  List<Station> _withoutHidden(List<Station> list) {
    final hidden = hiddenStationSlugs.value;
    if (hidden.isEmpty) return list;
    final slugs = hidden.toSet();
    return list.where((s) => !slugs.contains(s.slug)).toList();
  }

  /// Synchronous: the instance loaded at startup already holds the value.
  void _initHiddenStationSlugs() {
    final stored =
        GetIt.instance<SharedPreferences>().getString(_hiddenStationsKey);
    if (stored == null) return;
    try {
      hiddenStationSlugs.add(List<String>.from(json.decode(stored)));
    } catch (e) {
      _log("Error loading hidden stations: $e");
    }
  }

  // ---------------------------------------------------------------------------
  // Initial data loading
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    _log("bootstrap: loading cached/fallback stations");

    // Load persisted private stations first, so the very first publish already
    // pins them ahead of the public cache before the network responds.
    _bootstrapPrivateStations();

    final cached = await _loadCachedStations();
    final hasCachedData = cached != null;
    if (hasCachedData) {
      _log("bootstrap: ${cached.stations.length} stations from cache");
      _applyStationsData(cached);
    } else {
      final fallback = await _loadFallbackStations();
      if (fallback != null) {
        _log("bootstrap: ${fallback.stations.length} stations from bundled fallback");
        _applyStationsData(fallback);
      } else if (_privateStations.isNotEmpty) {
        // No public cache/fallback, but we have persisted private stations —
        // publish them so the UI isn't blank while the network loads.
        _publishMerged(force: true);
      }
    }

    // Start the periodic timer + kick off a startup sync. With cached
    // data we don't await, so the UI lights up immediately and the
    // network refresh fills in over the next second or two. Without
    // cache we have to wait — there's nothing to render yet.
    resumePeriodic();
    if (hasCachedData) {
      unawaited(enqueueSync(SyncReason.startup));
    } else {
      PerformanceMonitor.startOperation('initial_stations_fetch');
      await enqueueSync(SyncReason.startup);
      PerformanceMonitor.endOperation('initial_stations_fetch');
    }
  }

  Future<Query$GetStations?> _loadCachedStations() async {
    try {
      final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
      final cachedJson = prefs.getString(_cachedStationsKey);
      if (cachedJson == null) return null;
      final data = json.decode(cachedJson) as Map<String, dynamic>;
      _injectTypenames(data);
      final parsed = Query$GetStations.fromJson(data);
      if (parsed.stations.length < _minStationsForCache) return null;
      return parsed;
    } catch (e) {
      _log("Error loading cached stations: $e");
      return null;
    }
  }

  /// Persists [data] for the next cold start, at most every
  /// [_stationsCacheMinInterval] unless the catalog's structure changed.
  ///
  /// The blob is ~140 KB and lives in the shared prefs file, so each write
  /// costs a UI-isolate encode plus a rewrite of the whole file. The live
  /// fields that change every refresh (now_playing, uptime) are replaced by
  /// the startup sync within a second of launch anyway.
  Future<void> _cacheStationsData(Query$GetStations data) async {
    final key = _stationsCacheKey(data);
    final lastAt = _lastCachedStationsAt;
    if (key == _lastCachedStationsKey &&
        lastAt != null &&
        _now().difference(lastAt) < _stationsCacheMinInterval) {
      return;
    }
    try {
      final SharedPreferences prefs = GetIt.instance<SharedPreferences>();
      final dataJson = data.toJson();
      final stationsList = dataJson['stations'] as List?;
      if (stationsList != null) {
        for (final station in stationsList) {
          if (station is Map<String, dynamic>) {
            station['total_listeners'] = null;
          }
        }
      }
      await prefs.setString(_cachedStationsKey, json.encode(dataJson));
      _lastCachedStationsKey = key;
      _lastCachedStationsAt = _now();
      _log("Cached ${data.stations.length} stations to prefs");
    } catch (e) {
      _log("Error caching stations: $e");
    }
  }

  /// Cheap fingerprint of what a cold start renders before the network
  /// answers: the station set, names, logos, stream URLs and groups.
  static String _stationsCacheKey(Query$GetStations data) => [
        for (final s in data.stations)
          '${s.id}|${s.slug}|${s.title}|${s.thumbnail_url}|${s.station_type}|'
              '${s.station_streams.map((e) => e.stream_url).join(',')}',
        for (final g in data.station_groups)
          'g${g.id}:${g.station_to_station_groups.length}',
      ].join(';');

  Future<Query$GetStations?> _loadFallbackStations() async {
    try {
      _log("Loading fallback stations from asset");
      final jsonString = await rootBundle.loadString('assets/fallback-stations.json');
      final data = (json.decode(jsonString) as Map<String, dynamic>)['data']
          as Map<String, dynamic>;
      _injectTypenames(data);
      return Query$GetStations.fromJson(data);
    } catch (e) {
      _log("Error loading fallback stations: $e");
      return null;
    }
  }

  /// Creates a Station with reviews_stats from the REST cache.
  Station _createStation(Query$GetStations$stations raw) {
    final stats = reviewsStatsCache[raw.id];
    return Station(
      rawStationData: raw,
      averageRating: stats?.averageRating ?? 0,
      numberOfReviews: stats?.numberOfReviews ?? 0,
    );
  }

  void _applyStationsData(Query$GetStations data) {
    _publicStations = data.stations.map(_createStation).toList();
    _publishMerged(force: true);
    stationGroups.add(data.station_groups);
  }

  /// Fetches stations + live metadata at [liveTs], merges, applies in a
  /// single UI update. Used by full-refresh paths only — live diffs skip the
  /// heavy GraphQL hop. When GraphQL fails, the live metadata is still
  /// applied to the stations already shown. Returns whether the live
  /// metadata was fetched.
  Future<bool> _fetchStationsWithMetadata(int liveTs) async {
    final results = await Future.wait<Object?>([
      _queryStations(),
      _fetchMetadata(liveTs),
    ]);
    final parsedData = results[0] as Query$GetStations?;
    final liveMetadata = results[1] as Map<int, Map<String, dynamic>>?;

    if (parsedData != null && parsedData.stations.length >= _minStationsForCache) {
      _lastCatalogAt = _now();
      _publicStations = [
        for (final raw in parsedData.stations)
          _withLiveMetadata(_createStation(raw), liveMetadata),
      ];
      _publishMerged(force: true);
      stationGroups.add(parsedData.station_groups);
      _cacheStationsData(parsedData);
    } else if (liveMetadata != null) {
      _applyLiveMetadata(liveMetadata);
    }
    return liveMetadata != null;
  }

  /// The GraphQL station list, or null when the query failed.
  Future<Query$GetStations?> _queryStations() async {
    try {
      final result = await graphqlClient.query(
        // noCache: nothing reads the GraphQL cache back (bootstrap uses its
        // own prefs copy), so normalizing ~270 entities into Hive on every
        // full refresh was pure UI-isolate and disk work.
        Options$Query$GetStations(fetchPolicy: FetchPolicy.noCache),
      );
      // Under ErrorPolicy.none a failed query returns its error in the
      // result instead of throwing.
      final exception = result.exception;
      if (exception != null) {
        _log("stations query failed: $exception");
        _noteFetchFailure(_catalogFailures, 'catalog', exception);
      } else {
        _noteFetchSuccess(_catalogFailures, 'catalog');
      }
      return result.parsedData;
    } catch (e) {
      _log("stations query failed: $e");
      _noteFetchFailure(_catalogFailures, 'catalog', e);
      return null;
    }
  }

  Station _withLiveMetadata(
    Station station,
    Map<int, Map<String, dynamic>>? liveMetadata,
  ) {
    final metadata = liveMetadata?[station.id];
    return metadata == null
        ? station
        : _mergeStationWithMetadata(station, metadata);
  }

  // ---------------------------------------------------------------------------
  // Private (device-allowlisted) stations
  // ---------------------------------------------------------------------------

  /// Loads persisted private stations synchronously during bootstrap. Failures
  /// are swallowed — a bad cache must never block the app from starting.
  void _bootstrapPrivateStations() {
    final rawStations = _privateStationsService.loadCachedRaw();
    if (rawStations == null || rawStations.isEmpty) return;
    final parsed = _parsePrivateStations(rawStations);
    if (parsed.isNotEmpty) {
      _privateStations = parsed;
      _log("bootstrap: ${parsed.length} private stations from cache");
    }
  }

  /// One private-stations fetch iteration, applying the outcome policy:
  /// - updated → re-parse and merge (freshness flows on the next publish);
  /// - emptyAuthoritative → drop any private stations we were showing;
  /// - notDeployed / transientFailure / skipped → keep the last known list.
  Future<void> _syncPrivateStations() async {
    final result = await _privateStationsService.fetch();
    switch (result.outcome) {
      case PrivateFetchOutcome.skipped:
      case PrivateFetchOutcome.notDeployed:
      case PrivateFetchOutcome.transientFailure:
        return;
      case PrivateFetchOutcome.emptyAuthoritative:
        if (_privateStations.isNotEmpty) {
          _privateStations = <Station>[];
          _publishMerged(force: true);
          _log("private: cleared (authoritative empty)");
        }
        return;
      case PrivateFetchOutcome.updated:
        _privateStations = _parsePrivateStations(result.rawStations!);
        // Change-gated: private now_playing / listeners / uptime.is_up are all
        // covered by [hasStationsChanged], so meaningful changes still emit
        // while identical polls stay quiet.
        _publishMerged();
        return;
    }
  }

  /// Turns raw private station maps (same shape as public `/stations`) into
  /// [Station]s. Reuses the shared reviews-stats sideload and the typename
  /// injection so private stations parse exactly like public ones.
  List<Station> _parsePrivateStations(List<Map<String, dynamic>> rawStations) {
    if (rawStations.isEmpty) return <Station>[];
    // Populate reviewsStatsCache before parsing — Station reads it in
    // _createStation. Shared with the public GetStations transform.
    sideloadReviewsStats(rawStations);
    // Inject __typename in place so Query$GetStations$stations.fromJson parses.
    _injectTypenames(<String, dynamic>{'stations': rawStations});
    final result = <Station>[];
    for (final raw in rawStations) {
      try {
        result.add(_createStation(Query$GetStations$stations.fromJson(raw)));
      } catch (e) {
        _log("private parse: skipping malformed station: $e");
      }
    }
    return result;
  }

  /// Test seam: injects the parsed private station list and republishes the
  /// merged catalog, bypassing the network. Mirrors what [_syncPrivateStations]
  /// does on an `updated` outcome.
  @visibleForTesting
  void applyPrivateStationsForTest(List<Station> privateStations) {
    _privateStations = List<Station>.of(privateStations);
    _publishMerged(force: true);
  }

  /// Test seam: replaces the public station list and republishes, mirroring a
  /// full refresh or metadata merge, so tests can prove private stations
  /// survive public-only updates.
  @visibleForTesting
  void applyPublicStationsForTest(List<Station> publicStations) {
    _publicStations = List<Station>.of(publicStations);
    _publishMerged(force: true);
  }

  /// Test seam: what [initialize] does once the catalog is first known.
  @visibleForTesting
  Future<void> keepShownFavoriteOrderForTest() => _keepShownFavoriteOrder();

  // ---------------------------------------------------------------------------
  // REST metadata fetch
  // ---------------------------------------------------------------------------

  /// Fetches metadata from REST API.
  /// When [changesFromTimestamp] is provided, only returns stations that
  /// changed since that timestamp (differential update, like the
  /// radiocrestin.ro web app). A diff with the same parameters as the
  /// [timeline]'s last successful one lists no changes, without a request
  /// ([_lastDiffUrl]). [timeline] also labels the logs.
  Future<Map<int, Map<String, dynamic>>?> _fetchMetadata(
    int timestamp, {
    int? changesFromTimestamp,
    String timeline = 'live',
  }) async {
    var url = '${CONSTANTS.STATIONS_METADATA_URL}?timestamp=$timestamp';
    if (changesFromTimestamp != null && changesFromTimestamp > 0) {
      url += '&changes_from_timestamp=$changesFromTimestamp';
    }
    final isDiff = changesFromTimestamp != null && changesFromTimestamp > 0;
    final mode = '$timeline ${isDiff ? 'diff' : 'full'}';
    if (isDiff && _lastDiffUrl[timeline] == url) {
      _log("= metadata fetch [$mode] ts=$timestamp skipped: same request");
      return <int, Map<String, dynamic>>{};
    }
    final stopwatch = Stopwatch()..start();
    _log("→ metadata fetch [$mode] ts=$timestamp"
        "${isDiff ? ' from=$changesFromTimestamp' : ''}");
    // Any answer, even an error status, proves the internet works; no
    // answer makes NetworkService check it.
    var answered = false;
    try {
      // The 8 s covers the retry too, so an outage reports no later.
      final response = await _getRetryingTransportFailure(
              Uri.parse(url), '[$mode] ts=$timestamp')
          .timeout(const Duration(seconds: 8));
      answered = true;
      NetworkService.instance.reportRequestSuccess();
      stopwatch.stop();
      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final stationsMetadata = (jsonData['data']?['stations_metadata'] as List?) ?? [];
        final map = <int, Map<String, dynamic>>{};
        for (final item in stationsMetadata) {
          if (item is Map<String, dynamic> && item['id'] != null) {
            map[item['id'] as int] = item;
          }
        }
        if (isDiff) {
          _lastDiffUrl[timeline] = url;
        } else {
          _lastDiffUrl.remove(timeline);
        }
        _log("✓ metadata fetch [$mode] ts=$timestamp "
            "→ ${map.length} stations in ${stopwatch.elapsedMilliseconds}ms");
        _noteFetchSuccess(_metadataFailures, 'metadata');
        return map;
      } else {
        _log("✗ metadata fetch [$mode] ts=$timestamp "
            "→ HTTP ${response.statusCode} in ${stopwatch.elapsedMilliseconds}ms");
        _noteFetchFailure(
            _metadataFailures, 'metadata', 'HTTP ${response.statusCode}');
        return null;
      }
    } catch (e) {
      stopwatch.stop();
      if (!answered) NetworkService.instance.reportRequestFailure();
      _log("✗ metadata fetch [$mode] ts=$timestamp "
          "→ error in ${stopwatch.elapsedMilliseconds}ms: $e");
      _noteFetchFailure(_metadataFailures, 'metadata', e);
      return null;
    }
  }

  /// GETs [uri], once more at once if the request failed in transport.
  ///
  /// Connections stay open between ticks, so a request can go out on one
  /// the server or a NAT has just closed ("Connection closed before full
  /// header was received", a reset). That is no outage and must not reach
  /// NetworkService as one. dart:io drops the dead connection, so the
  /// retry goes out on another. An HTTP error status is an answer and a
  /// timeout is the caller's: neither is retried.
  Future<http.Response> _getRetryingTransportFailure(
      Uri uri, String label) async {
    try {
      return await _http.get(uri);
    } catch (e) {
      if (!_isTransportFailure(e)) rethrow;
      _log("↻ metadata fetch $label connection lost, retrying: $e");
      return _http.get(uri);
    }
  }

  /// Whether [error] is the connection failing rather than the API
  /// answering. [IOClient] reports dart:io's socket and HTTP errors as
  /// [http.ClientException]s.
  static bool _isTransportFailure(Object error) =>
      error is http.ClientException ||
      error is SocketException ||
      error is HttpException;

  /// Merges lightweight live metadata (uptime, now_playing, listeners) into
  /// an existing station. Preserves all other fields (station_streams,
  /// posts, reviews, etc.).
  Station _mergeStationWithMetadata(
    Station station,
    Map<String, dynamic> metadata,
  ) =>
      _rebuild(station, (json) {
        _withUptime(json, metadata['uptime']);
        final nowPlaying = metadata['now_playing'];
        if (nowPlaying is! Map<String, dynamic>) return json;
        json['total_listeners'] = nowPlaying['listeners'];
        return _withNowPlaying(json, nowPlaying);
      });

  /// Rebuilds [station] from its JSON after [edit], keeping its review
  /// stats.
  Station _rebuild(
    Station station,
    Map<String, dynamic> Function(Map<String, dynamic> json) edit,
  ) {
    final stats = reviewsStatsCache[station.id];
    return Station(
      rawStationData: Query$GetStations$stations.fromJson(
          edit(station.rawStationData.toJson())),
      averageRating: stats?.averageRating ?? station.averageRating,
      numberOfReviews: stats?.numberOfReviews ?? station.reviewCount,
    );
  }

  static void _withUptime(Map<String, dynamic> stationJson, Object? uptime) {
    if (uptime is! Map<String, dynamic>) return;
    stationJson['uptime'] = {
      '__typename': 'StationUptimeType',
      'is_up': uptime['is_up'],
      'latency_ms': uptime['latency_ms'],
      'timestamp': uptime['timestamp'],
    };
  }

  /// [stationJson] with `now_playing` taken from an API-shaped [nowPlaying]
  /// (live list, history row or B14 hint). Shared by the live merge and the
  /// audible overlay.
  static Map<String, dynamic> _withNowPlaying(
    Map<String, dynamic> stationJson,
    Map<String, dynamic> nowPlaying,
  ) {
    final previous = stationJson['now_playing'];
    stationJson['now_playing'] = {
      '__typename': 'StationNowPlayingType',
      // The metadata API has no now_playing.id; keep the previous one.
      'id': previous is Map<String, dynamic> ? previous['id'] ?? 0 : 0,
      'timestamp': nowPlaying['timestamp'],
      'song': _songJson(nowPlaying['song']),
    };
    return stationJson;
  }

  /// GraphQL `SongType` JSON, or null when [song] lacks an id or a name.
  static Map<String, dynamic>? _songJson(Object? song) {
    if (song is! Map<String, dynamic>) return null;
    if (song['id'] is! int || song['name'] is! String) return null;
    final artist = song['artist'];
    final hasArtist = artist is Map<String, dynamic> &&
        artist['id'] is int &&
        artist['name'] is String;
    return {
      '__typename': 'SongType',
      'id': song['id'],
      'name': song['name'],
      'thumbnail_url': song['thumbnail_url'],
      'artist': hasArtist
          ? {
              '__typename': 'ArtistType',
              'id': artist['id'],
              'name': artist['name'],
              'thumbnail_url': artist['thumbnail_url'],
            }
          : null,
    };
  }

  // ---------------------------------------------------------------------------
  // Station ordering & navigation (single source of truth)
  // ---------------------------------------------------------------------------

  /// Returns stations sorted by the user's saved sort preference.
  /// This is THE single source of truth for station order across
  /// phone, CarPlay, and Android Auto.
  ///
  /// [applyGroupFilter] narrows the result to the station group picked on
  /// the phone's home screen. Car and media-browser callers pass `false`:
  /// the group cannot be seen or changed from the car, so they always get
  /// the full catalog (in the same order). Hidden stations are left out
  /// either way.
  ///
  /// The sort order is cached so it stays stable during the session.
  /// It only re-sorts on manual refresh, sort option change, or when
  /// the station set changes (new/removed stations).
  List<Station> getSortedStations({bool applyGroupFilter = true}) =>
      _sortStations(
          applyGroupFilter ? filteredStations.value : visibleStations);

  /// The chosen group's stations in the order of [getSortedStations], the
  /// hidden ones too, each in the place it would have on show; empty
  /// without a chosen group. The home page lists them this way once all of
  /// a group's stations are hidden.
  List<Station> getSortedGroupStationsWithHidden() {
    final group = selectedStationGroup.value;
    if (group == null) return const [];
    return _sortStations(filterByGroup(group, stations.value));
  }

  /// [allStations] in the order [getSortedStations] describes. A hidden
  /// station keeps its place in the cached orders, so showing it again puts
  /// it back where it was.
  List<Station> _sortStations(List<Station> allStations) {
    if (allStations.isEmpty) return allStations;
    final sortOption = StationSortService.loadSavedSort();

    // Recommended ("Pentru tine") is frozen once per session — the single
    // source of truth shared by phone, TV, desktop, CarPlay and Android Auto.
    // It already pins private stations ahead of the frozen public order.
    if (sortOption == StationSortOption.recommended) {
      return _applyFrozenRecommendedOrder(allStations);
    }

    // Private stations are pinned first (in backend order); everything below
    // sorts / caches over the PUBLIC remainder exactly as before.
    final privatePinned = _orderedPrivateFrom(allStations);
    final privateIds = _privateOnlyIds;
    final publicOnly =
        allStations.where((s) => !privateIds.contains(s.id)).toList();

    // User-chosen sorts: cache the slug order so it stays stable during the
    // session. Re-sort only when the user picks a different option (count
    // changes append/drop instead of busting the cache).
    final cacheValid =
        _cachedSortOrder != null && _cachedSortOption == sortOption;

    if (!cacheValid) {
      // Sort the FULL public set, not just the group being shown: the cache
      // outlives group changes and is shared with the unfiltered car lists,
      // so a group-only cache would leave every other station unsorted.
      // [publicOnly] is merged in because [filteredStations] can be one
      // emission ahead of or behind [stations].
      final fullPublic = <String, Station>{
        for (final s in stations.value)
          if (!privateIds.contains(s.id)) s.slug: s,
        for (final s in publicOnly) s.slug: s,
      }.values.toList();

      // Refresh play counts from disk so the Android Auto engine (separate
      // isolate) sees counts written by the phone engine this session.
      final playCountService = GetIt.instance.isRegistered<PlayCountService>()
          ? GetIt.instance<PlayCountService>()
          : null;
      playCountService?.refresh();
      final sorted = StationSortService.sort(
        stations: fullPublic,
        sortBy: sortOption,
        playCounts: playCountService?.playCounts ?? <String, int>{},
        favoriteSlugs: favoriteStationSlugs.value,
      ).sorted;

      _cachedSortOrder = sorted.map<String>((s) => s.slug).toList();
      _cachedSortOption = sortOption;
    }

    return [...privatePinned, ..._projectByCachedOrder(publicOnly)];
  }

  /// Orders [publicOnly] by the cached slug order, keeping each station's
  /// fresh metadata (listeners, now_playing). Stations missing from the
  /// cache (added since the last sort) are appended at the end, so existing
  /// positions never shift.
  List<Station> _projectByCachedOrder(List<Station> publicOnly) {
    final bySlug = {for (final s in publicOnly) s.slug: s};
    final result = <Station>[];
    for (final slug in _cachedSortOrder!) {
      final station = bySlug.remove(slug);
      if (station != null) result.add(station);
    }
    result.addAll(bySlug.values);
    return result;
  }

  /// Extracts the private stations present in [source], ordered by their
  /// position in the backend-provided private list (stable among themselves).
  List<Station> _orderedPrivateFrom(List<Station> source) {
    final privateIds = _privateOnlyIds;
    if (privateIds.isEmpty) return const <Station>[];
    final orderIndex = <int, int>{};
    for (var i = 0; i < _privateStations.length; i++) {
      orderIndex[_privateStations[i].id as int] = i;
    }
    final result = source.where((s) => privateIds.contains(s.id)).toList();
    result.sort((a, b) =>
        (orderIndex[a.id as int] ?? 0).compareTo(orderIndex[b.id as int] ?? 0));
    return result;
  }

  /// Keeps [orderedStations] in sync with the frozen recommended order as
  /// fresh metadata flows in. Registered before [_bootstrap] so the very
  /// first `stations.add` is captured.
  void _initOrderedStationsStream() {
    stations.stream.listen(
      (all) => orderedStations.add(_applyFrozenRecommendedOrder(all)),
    );
  }

  /// Re-applies the frozen recommended slug order to [source].
  ///
  /// On first call with a non-empty station set, computes the recommended
  /// order once over the FULL station set and freezes it as a slug list, so
  /// the stream-driven and [getSortedStations] callers can never diverge.
  /// Thereafter it just maps the frozen order onto whatever (possibly
  /// group-filtered) [source] is passed in: removed stations drop out and
  /// genuinely-new stations are appended at the end — positions never shift.
  List<Station> _applyFrozenRecommendedOrder(List<Station> source) {
    // Private stations are pinned first and never enter the frozen public
    // order — they can be added/removed mid-session without shifting a single
    // public position.
    final privatePinned = _orderedPrivateFrom(source);
    final privateIds = _privateOnlyIds;
    final publicSource =
        source.where((s) => !privateIds.contains(s.id)).toList();

    if (_frozenRecommendedOrder == null) {
      final full = stations.value
          .where((s) => !privateIds.contains(s.id))
          .toList();
      if (full.isEmpty) {
        // No public stations to freeze yet.
        return [...privatePinned, ...publicSource];
      }
      final playCountService = GetIt.instance.isRegistered<PlayCountService>()
          ? GetIt.instance<PlayCountService>()
          : null;
      playCountService?.refresh();
      final playCounts = playCountService?.playCounts ?? <String, int>{};
      final sorted = StationSortService.sort(
        stations: full,
        sortBy: StationSortOption.recommended,
        playCounts: playCounts,
        favoriteSlugs: favoriteStationSlugs.value,
      ).sorted;
      _frozenRecommendedOrder = sorted.map<String>((s) => s.slug).toList();
    }

    final bySlug = {for (final s in publicSource) s.slug: s};
    final orderedPublic = <Station>[];
    for (final slug in _frozenRecommendedOrder!) {
      final station = bySlug.remove(slug);
      if (station != null) orderedPublic.add(station);
    }
    // Genuinely-new public stations (not in the frozen order) go at the end.
    orderedPublic.addAll(bySlug.values);
    return [...privatePinned, ...orderedPublic];
  }

  /// Invalidates the cached order for the user-chosen sort options, forcing a
  /// re-sort on the next [getSortedStations]. Call this only on an explicit
  /// user sort-option change. Deliberately does NOT touch
  /// [_frozenRecommendedOrder] — the recommended order stays frozen for the
  /// whole session even if the user toggles to another sort and back.
  void invalidateSortCache() {
    _cachedSortOrder = null;
    _cachedSortOption = null;
    sortOrderChanged.add(null);
  }

  /// Returns the station after [currentSlug] in the navigation playlist,
  /// wrapping around to the first one at the end.
  ///
  /// [wholeCatalog] ignores the group the phone shows, for a connected car:
  /// its lists always show every station.
  Station? getNextStation(String currentSlug, {bool wholeCatalog = false}) =>
      _stepStation(currentSlug, forward: true, wholeCatalog: wholeCatalog);

  /// Returns the station before [currentSlug] in the navigation playlist,
  /// wrapping around to the last one at the beginning. See
  /// [getNextStation] for [wholeCatalog].
  Station? getPreviousStation(
    String currentSlug, {
    bool wholeCatalog = false,
  }) =>
      _stepStation(currentSlug, forward: false, wholeCatalog: wholeCatalog);

  Station? _stepStation(
    String currentSlug, {
    required bool forward,
    required bool wholeCatalog,
  }) {
    final base = _navigationBase(currentSlug, wholeCatalog: wholeCatalog);
    final playlist = _navigationPlaylist(base);
    if (playlist.isEmpty) return null;
    final step = forward ? 1 : -1;
    final idx = playlist.indexWhere((s) => s.slug == currentSlug);
    if (idx >= 0) return playlist[(idx + step) % playlist.length];

    // The current station left the playlist (e.g. it was just removed from
    // favorites): continue from its slot in the sorted order. A hidden one
    // is in no list, so its slot is in the whole catalog's order.
    final order = base.any((s) => s.slug == currentSlug)
        ? base
        : _sortStations(stations.value);
    final orderIdx = order.indexWhere((s) => s.slug == currentSlug);
    if (orderIdx >= 0) {
      final slugs = playlist.map((s) => s.slug).toSet();
      for (var i = 1; i < order.length; i++) {
        final candidate = order[(orderIdx + i * step) % order.length];
        if (slugs.contains(candidate.slug)) return candidate;
      }
    }
    return forward ? playlist.first : playlist.last;
  }

  /// The sorted list [currentSlug] is navigated within: the group-filtered
  /// list the phone shows, or the full catalog with [wholeCatalog], after a
  /// pick from a car category (listed in the full catalog's order) or when
  /// the station sits outside the selected group (picked from search or
  /// from a link).
  List<Station> _navigationBase(
    String currentSlug, {
    required bool wholeCatalog,
  }) {
    final filtered = getSortedStations();
    if (!wholeCatalog &&
        startedFromGroup == null &&
        filtered.any((s) => s.slug == currentSlug)) {
      return filtered;
    }
    final all = getSortedStations(applyGroupFilter: false);
    return all.any((s) => s.slug == currentSlug) ? all : filtered;
  }

  /// Narrows [base] to the car category or the favorites playback started
  /// from. Falls back to [base] while fewer than two of their stations are
  /// in it: a lone station would be its own next, so the skip buttons would
  /// do nothing.
  List<Station> _navigationPlaylist(List<Station> base) {
    final List<Station> narrowed;
    if (_groupStationIds(startedFromGroup) case final ids?) {
      narrowed = base.where((s) => ids.contains(s.id)).toList();
    } else if (startedFromFavorites) {
      // In the listener's order, as the Favorite section shows them.
      narrowed = favoritesIn(base);
    } else {
      return base;
    }
    return narrowed.length < 2 ? base : narrowed;
  }

  /// The station ids of the group with [slug]; null without a slug or when
  /// the API no longer lists that group.
  Set<int>? _groupStationIds(String? slug) {
    if (slug == null) return null;
    final group =
        stationGroups.value.where((g) => g.slug == slug).firstOrNull;
    if (group == null) return null;
    return {for (final e in group.station_to_station_groups) e.station_id};
  }

  /// The car "Categories" (CarPlay's grid, Android Auto's tab): the station
  /// groups in the app's order, with the stations the listener can see.
  CarCategoryLayout carCategoryLayout() {
    final groups = stationGroups.value;
    final indexed = [for (var i = 0; i < groups.length; i++) (i, groups[i])]
      ..sort((a, b) {
        final byOrder = a.$2.order.compareTo(b.$2.order);
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
    return CarCategoryLayout.compute(
      groups: [
        for (final (_, group) in indexed)
          CarCategory(
            id: group.id,
            slug: group.slug,
            name: group.name,
            stationIds: {
              for (final link in group.station_to_station_groups)
                link.station_id,
            },
          ),
      ],
      knownStationIds: {for (final s in visibleStations) s.id as int},
    );
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  void _initFilteredStationsStream() {
    Rx.combineLatest3<Query$GetStations$station_groups?, List<Station>,
        List<String>, List<Station>>(
      selectedStationGroup.stream,
      stations.stream,
      hiddenStationSlugs.stream,
      (group, all, hidden) =>
          filterByGroup(group, all, hiddenSlugs: hidden.toSet()),
    ).listen((filtered) => filteredStations.add(filtered));
  }

  /// The [filteredStations] combiner: [allStations] ordered by `order`,
  /// without the [hiddenSlugs], narrowed to [group] when one is selected.
  ///
  /// Always returns a new list and never mutates its inputs: [allStations]
  /// is the published [stations] value, which the change gate compares
  /// against the next merge in API order. Ties keep their input order,
  /// because `List.sort` is unstable above 32 elements and the API sends
  /// every station with the same `order`.
  @visibleForTesting
  static List<Station> filterByGroup(
    Query$GetStations$station_groups? group,
    List<Station> allStations, {
    Set<String> hiddenSlugs = const {},
  }) {
    final indexed = [
      for (var i = 0; i < allStations.length; i++)
        if (!hiddenSlugs.contains(allStations[i].slug)) (i, allStations[i]),
    ];
    indexed.sort((a, b) {
      final byOrder =
          (a.$2.order as int? ?? 0).compareTo(b.$2.order as int? ?? 0);
      return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
    });
    final ordered = [for (final e in indexed) e.$2];
    if (group == null) return ordered;
    final ids = {
      for (final e in group.station_to_station_groups) e.station_id,
    };
    return ordered.where((s) => ids.contains(s.id)).toList();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Whether [newStations] differs from [oldStations] in anything the UI,
  /// CarPlay or Android Auto shows (title, song, artist, artwork,
  /// listeners, availability).
  @visibleForTesting
  static bool hasStationsChanged(
    List<Station> oldStations,
    List<Station> newStations,
  ) {
    if (oldStations.length != newStations.length) return true;
    for (int i = 0; i < oldStations.length; i++) {
      final o = oldStations[i];
      final n = newStations[i];
      if (o.id != n.id ||
          o.title != n.title ||
          o.thumbnailUrl != n.thumbnailUrl ||
          o.songId != n.songId ||
          o.songTitle != n.songTitle ||
          o.songArtist != n.songArtist ||
          _songThumbnailOf(o) != _songThumbnailOf(n) ||
          o.totalListeners != n.totalListeners ||
          o.isUp != n.isUp) {
        return true;
      }
    }
    return false;
  }

  static String? _songThumbnailOf(Station station) =>
      station.rawStationData.now_playing?.song?.thumbnail_url;

  void _injectTypenames(Map<String, dynamic> data, [String typename = 'queryRoot']) {
    data['__typename'] = typename;
    for (final entry in data.entries) {
      final childType = _fieldTypenames[entry.key];
      if (childType == null) continue;
      if (entry.value is List) {
        for (final item in entry.value) {
          if (item is Map<String, dynamic>) _injectTypenames(item, childType);
        }
      } else if (entry.value is Map<String, dynamic>) {
        _injectTypenames(entry.value, childType);
      }
    }
  }

  void _preCacheStationThumbnails() {
    if (NetworkService.instance.isOnMobileData.value) return;
    final urls = stations.value
        .where((s) => s.thumbnailUrl != null && s.thumbnailUrl!.isNotEmpty)
        .map((s) => s.thumbnailUrl!)
        .toList();
    if (urls.isEmpty) return;
    ImageCacheService.instance.preCacheUrls(urls);
  }

  /// In unstable connection mode, pre-cache all song thumbnails permanently to disk.
  void _preCacheSongThumbnails(List<Station> stationsList) {
    final urls = stationsList
        .where((s) => s.rawStationData.now_playing?.song?.thumbnail_url != null)
        .map((s) => s.rawStationData.now_playing!.song!.thumbnail_url!)
        .where((url) => url.isNotEmpty)
        .toSet() // deduplicate
        .toList();
    if (urls.isEmpty) return;
    _log("Pre-caching ${urls.length} song thumbnails (unstable mode)");
    ImageCacheService.instance.preCacheUrls(urls);
  }
}
