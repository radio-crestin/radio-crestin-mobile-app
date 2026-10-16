import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/performance_monitor.dart';
import 'package:radio_crestin/resilient_hive_store.dart';
import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:upgrader/upgrader.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/theme_manager.dart';
import 'package:radio_crestin/seek_mode_manager.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'appAudioHandler.dart';
import 'constants.dart';
import 'firebase_options.dart';
import 'globals.dart' as globals;
import 'services/car_play_service.dart';
import 'types/Station.dart';
import 'services/cast_service.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart'
    show CastMediaPlayerState;
import 'services/tv_channel_service.dart';
import 'package:flutter_airplay/flutter_airplay.dart' as flutter_airplay;
import 'services/analytics_service.dart';
import 'services/app_start_log.dart';
import 'services/device_registration_service.dart';
import 'services/error_filter.dart';
import 'services/hls_health_watchdog_flag.dart';
import 'services/hls_start_variant.dart';
import 'services/hls_timeline.dart';
import 'services/home_widget_service.dart';
import 'services/image_cache_service.dart';
import 'services/log_context.dart';
import 'services/log_flush_guard.dart';
import 'services/remote_debug_controller.dart';
import 'services/quick_actions_service.dart';
import 'services/network_service.dart';
import 'services/play_count_service.dart';
import 'services/song_like_service.dart';
import 'services/station_data_service.dart';
import 'services/video_playback_service.dart';
import 'services/playlist_sync_service.dart';
import 'services/playlist_controller.dart';
import 'tv/tv_platform.dart';
import 'tv/tv_shell.dart';
import 'tv/tv_theme.dart';

final getIt = GetIt.instance;

Future<void> initializeFirebaseMessaging() async {
  try {
    if (Platform.isIOS) {
      FirebaseMessaging messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        announcement: true,
        badge: true,
        carPlay: false,
        criticalAlert: true,
        provisional: true,
        sound: true,
      );
    } else {
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      try {
        final fcmToken = await FirebaseMessaging.instance.getToken();
        if (fcmToken != null) globals.fcmToken = fcmToken;
        developer.log("FCMToken $fcmToken");
      } catch (e) {
        developer.log("Failed to get FCM token: $e");
        if (e.toString().contains('SERVICE_NOT_AVAILABLE')) {
          developer.log("Firebase Messaging service not available - likely running on emulator without Google Play Services");
        }
      }
      // FCM rotates tokens (and may deliver the first one late, after a
      // failed getToken), so keep the backend's copy current.
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        if (token == globals.fcmToken) return;
        globals.fcmToken = token;
        DeviceRegistrationService.instance.register();
      }, onError: (Object _) {});
    }
  } catch (e, stackTrace) {
    developer.log("Firebase Messaging initialization failed", error: e, stackTrace: stackTrace);
    if (!e.toString().contains('SERVICE_NOT_AVAILABLE')) {
      AnalyticsService.instance.captureException(e, stackTrace, context: 'firebase_messaging_init');
    }
  }
}

// Firebase plugins (messaging, app_installations, remote_config) don't support
// Windows/Linux desktop. Skip Firebase entirely on those platforms.
final bool _firebaseSupported =
    kIsWeb || Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

void main() async {
  PerformanceMonitor.markAppStart();

  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // Initialize sqflite FFI for desktop platforms (Windows/Linux/macOS).
  // The default sqflite plugin only ships native libs for Android/iOS.
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Register libmpv-backed just_audio implementation for Windows/Linux.
  // Must run before any AudioPlayer is constructed (i.e. before AudioService.init).
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    JustAudioMediaKit.ensureInitialized(
      windows: true,
      linux: true,
    );
  }

  // media_kit (the video-playback engine for TV channels + video playlist
  // items) is initialized LAZILY on first video use — VideoPlaybackService
  // .ensureInitialized() calls MediaKit.ensureInitialized() before it builds a
  // Player. Deferring it keeps its native-library registration off the startup
  // path for the common audio-only launch (measured on first video instead).

  // Phase 1: Start ALL independent async operations in parallel.
  // Firebase, Hive, SharedPreferences, image cache, network, and PackageInfo
  // have no dependencies on each other — run them all concurrently.
  final Future<void> firebaseInitFuture = _firebaseSupported
      ? PerformanceMonitor.trackAsync('firebase_init', () =>
          Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
        )
      : Future.value();

  final hiveStoreFuture = PerformanceMonitor.trackAsync<Store>('hive_store_init', () async {
    try {
      await initHiveForFlutter();
      return await ResilientHiveStore.create();
    } catch (e) {
      developer.log('HiveStore init failed, using InMemoryStore: $e');
      return InMemoryStore() as Store;
    }
  });

  final prefsFuture = SharedPreferences.getInstance();
  final packageInfoFuture = PackageInfo.fromPlatform();
  // Neither needs Hive or GetIt; both are awaited before AudioService.init.
  // TV detection is a device-info platform call; the likes DB open + cache
  // load never throws (memory-only fallback), so it is safe to start early.
  final tvPlatformFuture = TvPlatform.initialize();
  final songLikeFuture = SongLikeService.init();

  // Construct services early (sync constructors) and start their async init
  // in parallel with hive — they only need path_provider / connectivity, not hive.
  final networkService = NetworkService();
  final imageCacheService = ImageCacheService();

  final networkInitFuture = networkService.initialize();
  final imageCacheInitFuture = PerformanceMonitor.trackAsync('image_cache_init',
    () => imageCacheService.initialize());

  // Phase 2: Wait for hive + prefs (needed for GraphQL client).
  // Image cache and network init run in parallel — likely finish before hive.
  final hivePrefsResults = await Future.wait([hiveStoreFuture, prefsFuture]);
  final Store graphQlStore = hivePrefsResults[0] as Store;
  final SharedPreferences prefs = hivePrefsResults[1] as SharedPreferences;

  // Also ensure image cache and network are ready (should already be done)
  await Future.wait([imageCacheInitFuture, networkInitFuture]);

  // Set persistent device ID (survives reinstalls) — used for ?s= tracking,
  // reviews, share links, and the PostHog user identifier.
  String? persistentDeviceId = prefs.getString('device_id');
  if (persistentDeviceId == null) {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      persistentDeviceId = (await deviceInfo.androidInfo).id;
    } else if (Platform.isIOS) {
      persistentDeviceId = (await deviceInfo.iosInfo).identifierForVendor;
    }
    persistentDeviceId ??= DateTime.now().millisecondsSinceEpoch.toString();
    await prefs.setString('device_id', persistentDeviceId);
  }
  globals.deviceId = persistentDeviceId;

  // Detect TV/desktop platform (Android TV, macOS, Windows, Linux)
  await tvPlatformFuture;

  if (prefs.getString('_reviewStatus') == null) {
    var defaultReviewStatus = {
      'review_completed': false, // is completed when the user clicks on "5 stele" to add a review.
      'actions_made': 0,
    };
    prefs.setString('_reviewStatus', json.encode(defaultReviewStatus));
  }

  // GraphQL client setup (only needs hiveStore, not Firebase)
  final HttpLink httpLink = HttpLink(
    CONSTANTS.GRAPHQL_ENDPOINT,
  );

  final AuthLink authLink = AuthLink(
    getToken: () async => CONSTANTS.GRAPHQL_AUTH,
  );

  final queryToRestMap = createGraphQLToRestMappings();

  final graphqlToRestInterceptor = GraphQLToRestInterceptorLink(
    queryToRestMap: queryToRestMap,
  );

  final Link graphqlLink = graphqlToRestInterceptor.concat(authLink.concat(httpLink));
  final graphQlCache = GraphQLCache(store: graphQlStore);

  GraphQLClient graphqlClient = GraphQLClient(
    link: graphqlLink,
    cache: graphQlCache,
    // The 5 s default is too tight for the ~200 KB station catalog on slow
    // links (it never refreshes). 8 s matches the metadata call, so a full
    // refresh, which awaits both, does not hold the sync lock any longer.
    queryRequestTimeout: const Duration(seconds: 8),
    defaultPolicies: DefaultPolicies(
      query: Policies(
        fetch: FetchPolicy.cacheAndNetwork,
        error: ErrorPolicy.none,
        cacheReread: CacheRereadPolicy.mergeOptimistic,
      ),
      watchQuery: Policies(
        fetch: FetchPolicy.cacheAndNetwork,
        error: ErrorPolicy.none,
        cacheReread: CacheRereadPolicy.mergeOptimistic,
      ),
      mutate: Policies(
        fetch: FetchPolicy.cacheAndNetwork,
        error: ErrorPolicy.none,
        cacheReread: CacheRereadPolicy.mergeOptimistic,
      ),
      watchMutation: Policies(
        fetch: FetchPolicy.cacheAndNetwork,
        error: ErrorPolicy.none,
        cacheReread: CacheRereadPolicy.mergeOptimistic,
      ),
      subscribe: Policies(
        fetch: FetchPolicy.cacheAndNetwork,
        error: ErrorPolicy.none,
        cacheReread: CacheRereadPolicy.mergeOptimistic,
      ),
    ),
  );

  // Phase 3: Register all services with GetIt (sync, order matters).
  // Registration must happen BEFORE AudioService.init() because the builder
  // callback creates AppAudioHandler which accesses GetIt<StationDataService>.
  getIt.registerSingleton<SharedPreferences>(prefs);
  getIt.registerSingleton<NetworkService>(networkService);
  getIt.registerSingleton<ImageCacheService>(imageCacheService);

  // The seek offset sets the listening delay the station list follows, so
  // it is known before the first sync and tracked from then on.
  SeekModeManager.initializeFromPrefs(prefs);
  final stationDataService = StationDataService(graphqlClient: graphqlClient)
    ..getListeningDelay = _listeningDelay;
  SeekModeManager.offsetChanges
      .addListener(stationDataService.onListeningDelayChanged);
  getIt.registerSingleton<StationDataService>(stationDataService);

  final playCountService = PlayCountService();
  getIt.registerSingleton<PlayCountService>(playCountService);

  final songLikeService = await songLikeFuture;
  getIt.registerSingleton<SongLikeService>(songLikeService);

  // Video-playback engine + playlist orchestration. Registered before
  // AudioService.init so AppAudioHandler can resolve them lazily; the handler
  // and controller reference each other via GetIt (no constructor cycle).
  final videoPlaybackService = VideoPlaybackService();
  getIt.registerSingleton<VideoPlaybackService>(videoPlaybackService);
  final playlistSyncService = PlaylistSyncService();
  getIt.registerSingleton<PlaylistSyncService>(playlistSyncService);
  final playlistController = PlaylistController(
    videoService: videoPlaybackService,
    syncService: playlistSyncService,
  );
  getIt.registerSingleton<PlaylistController>(playlistController);

  // Phase 4: Start AudioService.init() — the biggest remaining blocker.
  // Network and image cache are already initialized (awaited above).
  final audioHandlerFuture = PerformanceMonitor.trackAsync('audio_service_init', () =>
    initAudioService(graphqlClient: graphqlClient),
  );

  // StationDataService init runs in parallel with audio (thumbnail pre-caching
  // depends on ImageCacheService which is already initialized).
  await PerformanceMonitor.trackAsync('station_data_init', () => stationDataService.initialize());

  // Now await Firebase (likely already done since audio init takes longer)
  await firebaseInitFuture;

  // Load the flag decisions cached by the previous launch, so they apply
  // from startup. Does not block on the network.
  await RemoteDebugController.instance.loadCache(prefs);
  await HlsHealthWatchdogFlag.instance.loadCache(prefs);

  // Developer mode (Settings hidden gesture) ships debug-level logs.
  AnalyticsService.instance
      .setDeveloperVerbose(prefs.getBool('developer_mode_enabled') ?? false);

  // packageInfo has been resolving since Phase 1 and is effectively instant
  // by now; awaiting it here lets PostHog Logs stamp `service.version`.
  final packageInfo = await packageInfoFuture;

  // Initialize PostHog analytics (error tracking is handled by PostHog config).
  // The onFeatureFlags callback lets the controllers apply the live flags once
  // PostHog has loaded them.
  await AnalyticsService.instance.initialize(
    onFeatureFlagsLoaded: () {
      unawaited(RemoteDebugController.instance.onFlagsLoaded());
      unawaited(HlsHealthWatchdogFlag.instance.onFlagsLoaded());
    },
    appVersion: packageInfo.version,
    prefs: prefs,
  );

  // Apply the cached remote-debug config (verbose logs, auto log upload).
  RemoteDebugController.instance.start();

  // Settle any flush owed from a previous offline exception (or a crash
  // before the flush completed) and watch connectivity for new debts.
  LogFlushGuard.instance.start(prefs);

  // Suppress known-benign runtime/network/plugin errors so they neither crash
  // the app nor drown out real issues in PostHog. Must run AFTER PostHog setup —
  // it wraps the FlutterError/PlatformDispatcher handlers PostHog just installed.
  ErrorFilter.install();

  globals.appVersion = packageInfo.version;
  globals.buildNumber = packageInfo.buildNumber;

  // Identify user immediately after PostHog init — before any events fire.
  // One call carries the full identity: packageInfo is already resolved.
  await AnalyticsService.instance.identify(
    userId: globals.deviceId,
    appVersion: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
    platform: Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : Platform.isMacOS ? 'macos' : Platform.isWindows ? 'windows' : Platform.isLinux ? 'linux' : 'other',
  );

  // From here on every info+ log record carries the device's state, and
  // the launch is marked in the log with what wrote it. After setup, so a
  // session the previous run left open is not reported with today's state.
  AnalyticsService.instance.setLogContextProvider(LogContext.current);
  unawaited(AppStartLog.write(
    prefs: prefs,
    appVersion: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
  ));

  if (prefs.getBool('_notificationsEnabled') ?? true) {
    AnalyticsService.instance.setUserProperty('personalized_n', 'true');
  }

  // The likes DB opened before PostHog was up, so a memory-only fallback
  // could not be reported at the time. After identify, so the error is
  // attributed to this device.
  final songLikeFailure = SongLikeService.initFailure;
  if (songLikeFailure != null) {
    AnalyticsService.instance.captureException(
      songLikeFailure.error,
      songLikeFailure.stackTrace,
      context: 'song_like_db_init',
    );
  }

  // Kept so the first device registration can wait for the FCM token.
  final Future<void> fcmInitFuture = _firebaseSupported
      ? PerformanceMonitor.trackAsync(
          'firebase_messaging_init', initializeFirebaseMessaging)
      : Future<void>.value();

  // Wait for audio (packageInfo already resolved above)
  final audioHandler = await audioHandlerFuture;
  getIt.registerSingleton<AppAudioHandler>(audioHandler);

  // Before runApp: a Home Screen widget's button may be what launched the
  // app, and waits for this to say it can take it.
  if (Platform.isIOS) {
    getIt.registerSingleton<HomeWidgetService>(HomeWidgetService(
      audioHandler: audioHandler,
      stationDataService: getIt<StationDataService>(),
      playCountService: getIt<PlayCountService>(),
      prefs: prefs,
    )..start());
  }

  // Initialize theme synchronously using already-loaded prefs (no async overhead)
  ThemeManager.initializeFromPrefs(prefs);

  PerformanceMonitor.markAppReady();
  PerformanceMonitor.startFrameMonitoring();

  // Print performance report after 15 seconds to capture startup + first interactions
  if (!kReleaseMode) {
    Future.delayed(const Duration(seconds: 15), () {
      PerformanceMonitor.printReport();
    });
  }

  runApp(const RadioCrestinApp());

  // Remove native splash AFTER runApp + first frame layout to prevent
  // "Cannot hit test a render box that has never been laid out" errors
  // from touch events arriving before the widget tree is laid out.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    FlutterNativeSplash.remove();
  });

  // Initialize quick actions after runApp so the Android Activity is available
  WidgetsBinding.instance.addPostFrameCallback((_) {
    QuickActionsService.initialize();
  });

  // Pre-warm the network path to the last-played station's stream so the first
  // tap of the session starts faster. Fire-and-forget; never blocks startup.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (getIt.isRegistered<AppAudioHandler>()) {
      unawaited(getIt<AppAudioHandler>().prewarmLastPlayed());
    }
  });

  // Upsert this device's details to our backend in the background. Fire-and-
  // forget — never blocks startup; runs on every launch so the stored model,
  // OS, app version, locale and FCM token stay current. The IP is recorded
  // server-side. Deferred to post-frame so it never competes with first paint.
  // On a fresh install the FCM token needs a round trip to FCM, so wait for
  // it (bounded) or the backend would only get the token on the next launch.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(fcmInitFuture
        .timeout(const Duration(seconds: 5), onTimeout: () {})
        .whenComplete(() => DeviceRegistrationService.instance.register()));
  });

  // Defer CarPlay/Android Auto init to after first frame (mobile only)
  if (Platform.isIOS || Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final carPlayService = await PerformanceMonitor.trackAsync('carplay_service_init', () async {
        final service = CarPlayService();
        await service.initialize();
        return service;
      });
      getIt.registerSingleton<CarPlayService>(carPlayService);
    });
  }

  // Initialize Android TV home screen channels (favorites channel)
  if (TvPlatform.isTV && Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final tvChannelService = TvChannelService();
      await tvChannelService.initialize();
      getIt.registerSingleton<TvChannelService>(tvChannelService);
    });
  }

  // Defer Chromecast/AirPlay discovery to after first frame
  if (!TvPlatform.isTV) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final castService = CastService(prefs: getIt<SharedPreferences>());
      await castService.initialize();
      getIt.registerSingleton<CastService>(castService);

      // Chromecast session management — only one output at a time
      final audioHandler = getIt<AppAudioHandler>();
      audioHandler.watchCastSessions(castService);
      bool hasEverCasted = false;

      // ─── Cast session lifecycle ──────────────────────────────────
      //
      // On connect (user tap, or iOS auto-resuming a saved session at
      // app startup — both routes emit `isCasting=true` through this
      // same listener):
      //   1. Stop the local player so iOS doesn't keep the audio
      //      session active in parallel with the Cast output.
      //   2. Inspect the receiver's current MediaStatus:
      //      a) It's actively playing/paused/buffering one of our
      //         stations → ADOPT. Sync local currentStation /
      //         mediaItem, mark the session adopted so
      //         updateCastMetadata no-ops, and if it's anything but
      //         `playing`, send a play command — the user just picked
      //         us, they want audio out of this device.
      //      b) Otherwise (idle receiver, no match, or no session
      //         media yet) → PUSH our current/last station with a
      //         fresh loadMedia. `autoPlay` defaults to true in the
      //         plugin, so this starts playback automatically.
      //
      // On disconnect:
      //   - Explicitly stop the local player. iOS ends the Cast-side
      //     audio-session interruption when the remote device goes
      //     away, and without an explicit stop, just_audio can
      //     auto-resume the previously-loaded stream as if the user
      //     had tapped play (root cause of the "starts again after
      //     stopping from the app" regression).
      //   - Flip playbackState.playing=false via setCastPlaying so
      //     the notification ends up with MediaControl.play.
      castService.isCasting.distinct().listen((casting) async {
        print('[CastMain] isCasting=$casting');
        if (casting) {
          hasEverCasted = true;
          await audioHandler.player.stop();

          final existingStatus =
              await castService.waitForActiveMediaStatus();
          // On startup the station list may still be loading when the
          // iOS Cast SDK restores a saved session. Wait briefly for
          // the first non-empty emission so matchStationFromCastMedia
          // and getLastPlayedStation can do their jobs.
          final stations = await _waitForStations(
              getIt<StationDataService>());
          final adopted = castService.matchStationFromCastMedia(
              stations, existingStatus);
          final receiverState = existingStatus?.playerState;
          final receiverIsActive =
              receiverState == CastMediaPlayerState.playing ||
                  receiverState == CastMediaPlayerState.paused ||
                  receiverState == CastMediaPlayerState.buffering;

          if (adopted != null && receiverIsActive) {
            print('[CastMain] Adopting session: station=${adopted.slug}, '
                'playerState=$receiverState');
            castService.lastCastSlug = adopted.slug;
            castService.markSessionAdopted();
            await audioHandler.selectStation(adopted);
            // User just connected us: auto-play regardless of the
            // upstream sender's pause. Sending PLAY to an existing
            // media session doesn't reload it, so the adoption
            // contract (don't clobber their LOAD) still holds.
            if (receiverState != CastMediaPlayerState.playing) {
              castService.play();
            }
            audioHandler.setCastPlaying(true);
            return;
          }

          var station = audioHandler.currentStation.value;
          if (station == null) {
            station = await audioHandler.getLastPlayedStation();
            if (station != null) await audioHandler.selectStation(station);
          }
          if (station != null) {
            castService.lastCastSlug = station.slug;
            castService.castStation(station);
            audioHandler.setCastPlaying(true);
          }
        } else if (hasEverCasted) {
          castService.lastCastSlug = null;
          await audioHandler.player.stop();
          audioHandler.setCastPlaying(false);
          // Nothing plays after a disconnect; without this the silent
          // session keeps counting toward its `listening_stopped` duration.
          AnalyticsService.instance.endListening();
        }
      });

      // Catch station changes not initiated by playStation (e.g. auto-start)
      audioHandler.currentStation.listen((station) {
        if (station != null && castService.isCasting.value &&
            station.slug != castService.lastCastSlug) {
          castService.lastCastSlug = station.slug;
          castService.castStation(station);
        }
      });

      // ─── Cast receiver → local notification state sync ───────────
      //
      // Receiver-initiated transitions (another sender toggled play,
      // content ended, error) flow in via castPlayerState. Map every
      // known state to the single boolean `playing`:
      //   PLAYING                  → true
      //   PAUSED / IDLE            → false (receiver isn't playing)
      //   BUFFERING / LOADING /    → keep previous value — these are
      //   UNKNOWN                    transient; the next concrete
      //                              state will resolve.
      castService.castPlayerState.distinct().listen((playerState) {
        if (!castService.isCasting.value) return;
        switch (playerState) {
          case CastMediaPlayerState.playing:
            audioHandler.setCastPlaying(true);
            break;
          case CastMediaPlayerState.paused:
          case CastMediaPlayerState.idle:
            audioHandler.setCastPlaying(false);
            break;
          case CastMediaPlayerState.buffering:
          case CastMediaPlayerState.loading:
          case CastMediaPlayerState.unknown:
            // Transient — don't clobber the optimistic intent.
            break;
        }
      });

      // Auto-play on AirPlay connect (iOS only)
      if (Platform.isIOS) {
        final airplay = flutter_airplay.AirPlayRouteState.instance;
        airplay.isActiveStream.listen((active) async {
          if (active && audioHandler.currentStation.value == null) {
            final station = await audioHandler.getLastPlayedStation();
            if (station != null) audioHandler.playStation(station);
          }
        });
      }
    });
  }
}

/// How far behind live a station tapped now is heard: local time-shifted
/// HLS plays the seek offset plus how far its start trails the live edge
/// (see [HlsTimeline.approximateLatency]); a Cast receiver and Android TV
/// (live metadata) play live.
Duration _listeningDelay() {
  final getIt = GetIt.instance;
  final casting =
      getIt.isRegistered<CastService>() && getIt<CastService>().isCasting.value;
  if (casting || TvPlatform.isAndroidTV) return Duration.zero;
  final offset = SeekModeManager.currentOffset;
  return HlsTimeline.approximateLatency(
    offset,
    darwin: Platform.isIOS || Platform.isMacOS,
    startVariant: HlsStartVariant.isUsedAt(offset),
  );
}

/// Returns the current list of stations, waiting up to [timeout] for the
/// first non-empty emission. Used when the Cast-connect flow fires on
/// startup before the station catalog has loaded from cache/network.
Future<List<Station>> _waitForStations(
  StationDataService service, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final existing = service.stations.value;
  if (existing.isNotEmpty) return existing;
  try {
    return await service.stations.stream
        .firstWhere((s) => s.isNotEmpty)
        .timeout(timeout);
  } catch (_) {
    return service.stations.value;
  }
}

/// Re-checks the store on resume at most every 12 h.
///
/// Android reports `resumed` on every window-focus regain (e.g. closing the
/// notification shade), and each check downloads and parses the Play Store
/// page on the UI isolate. The launch check runs through `initialize()` and
/// is unaffected.
class _ThrottledUpgrader extends Upgrader {
  static const _minInterval = Duration(hours: 12);
  DateTime _lastCheck = DateTime.now();

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state != AppLifecycleState.resumed) return;
    final now = DateTime.now();
    if (now.difference(_lastCheck) < _minInterval) return;
    _lastCheck = now;
    await super.didChangeAppLifecycleState(state);
  }
}

/// One app-lifetime instance: building it inside the theme builder leaked an
/// observer and an HTTP client on every theme change.
final Upgrader _upgrader = _ThrottledUpgrader();

class RadioCrestinApp extends StatelessWidget {
  const RadioCrestinApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    // TV gets a dedicated dark theme and TV-optimized UI shell.
    if (TvPlatform.isTV) {
      return MaterialApp(
        navigatorKey: globals.navigatorKey,
        navigatorObservers: [PosthogObserver()],
        title: 'Radio Crestin',
        debugShowCheckedModeBanner: false,
        theme: tvTheme,
        darkTheme: tvTheme,
        themeMode: ThemeMode.dark,
        home: const TvShell(),
      );
    }

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeManager.themeMode,
      builder: (context, themeMode, child) {
        return MaterialApp(
          navigatorKey: globals.navigatorKey,
          navigatorObservers: [PosthogObserver()],
          title: 'Radio Crestin',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          home: UpgradeAlert(
            dialogStyle: Platform.isIOS
                ? UpgradeDialogStyle.cupertino
                : UpgradeDialogStyle.material,
            upgrader: _upgrader,
            child: const HomePage(),
          ),
        );
      },
    );
  }
}
