import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show PathNotFoundException, Platform;

import 'package:device_info_plus/device_info_plus.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

import 'appAudioHandler.dart';
import 'constants.dart';
import 'firebase_options.dart';
import 'globals.dart' as globals;
import 'services/car_play_service.dart';
import 'services/cast_service.dart';
import 'package:flutter_airplay/flutter_airplay.dart' as flutter_airplay;
import 'services/analytics_service.dart';
import 'services/image_cache_service.dart';
import 'services/quick_actions_service.dart';
import 'services/network_service.dart';
import 'services/play_count_service.dart';
import 'services/song_like_service.dart';
import 'services/station_data_service.dart';
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
        developer.log("FCMToken $fcmToken");
      } catch (e) {
        developer.log("Failed to get FCM token: $e");
        if (e.toString().contains('SERVICE_NOT_AVAILABLE')) {
          developer.log("Firebase Messaging service not available - likely running on emulator without Google Play Services");
        }
      }
    }
  } catch (e, stackTrace) {
    developer.log("Firebase Messaging initialization failed", error: e, stackTrace: stackTrace);
    if (!e.toString().contains('SERVICE_NOT_AVAILABLE')) {
      AnalyticsService.instance.captureException(e, stackTrace, context: 'firebase_messaging_init');
    }
  }
}

void main() async {
  PerformanceMonitor.markAppStart();

  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // Phase 1: Start ALL independent async operations in parallel.
  // Firebase, Hive, SharedPreferences, image cache, network, and PackageInfo
  // have no dependencies on each other — run them all concurrently.
  final firebaseInitFuture = PerformanceMonitor.trackAsync('firebase_init', () =>
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
  );

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
  // reviews, share links, and Firebase Crashlytics user identifier.
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
  await TvPlatform.initialize();

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

  final stationDataService = StationDataService(graphqlClient: graphqlClient);
  getIt.registerSingleton<StationDataService>(stationDataService);

  final playCountService = PlayCountService();
  getIt.registerSingleton<PlayCountService>(playCountService);

  final songLikeService = await SongLikeService.init();
  getIt.registerSingleton<SongLikeService>(songLikeService);

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

  // Initialize PostHog analytics (error tracking is handled by PostHog config)
  await AnalyticsService.instance.initialize();

  // Identify user immediately after PostHog init — before any events fire.
  // deviceId is already set above; appVersion/buildNumber come later.
  await AnalyticsService.instance.identify(
    userId: globals.deviceId,
    platform: Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : Platform.isMacOS ? 'macos' : Platform.isWindows ? 'windows' : Platform.isLinux ? 'linux' : 'other',
  );

  if (prefs.getBool('_notificationsEnabled') ?? true) {
    AnalyticsService.instance.setUserProperty('personalized_n', 'true');
  }

  PerformanceMonitor.trackAsync('firebase_messaging_init', () => initializeFirebaseMessaging());

  // Wait for audio + packageInfo
  final serviceResults = await Future.wait([audioHandlerFuture, packageInfoFuture]);
  getIt.registerSingleton<AppAudioHandler>(serviceResults[0] as AppAudioHandler);

  final packageInfo = serviceResults[1] as PackageInfo;
  globals.appVersion = packageInfo.version;
  globals.buildNumber = packageInfo.buildNumber;

  // Update PostHog user with app version info now that packageInfo is available
  await AnalyticsService.instance.identify(
    userId: globals.deviceId,
    appVersion: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
    platform: Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : Platform.isMacOS ? 'macos' : Platform.isWindows ? 'windows' : Platform.isLinux ? 'linux' : 'other',
  );

  // Initialize theme and seek mode synchronously using already-loaded prefs (no async overhead)
  ThemeManager.initializeFromPrefs(prefs);
  SeekModeManager.initializeFromPrefs(prefs);

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

  // Defer Chromecast/AirPlay discovery to after first frame
  if (!TvPlatform.isTV) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final castService = CastService();
      await castService.initialize();
      getIt.registerSingleton<CastService>(castService);

      // Auto-play + cast on Chromecast connect
      final audioHandler = getIt<AppAudioHandler>();
      castService.isCasting.listen((casting) async {
        if (casting) {
          var station = audioHandler.currentStation.value;
          // Nothing playing — start last played station automatically
          if (station == null) {
            station = await audioHandler.getLastPlayedStation();
            if (station != null) audioHandler.playStation(station);
          }
          if (station != null) castService.castStation(station);
        }
      });
      // Push metadata updates when song changes during active cast
      audioHandler.currentStation.listen((station) {
        if (station != null && castService.isCasting.value) {
          castService.castStation(station);
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

class RadioCrestinApp extends StatelessWidget {
  const RadioCrestinApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    // TV gets a dedicated dark theme and TV-optimized UI shell
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
            upgrader: Upgrader(),
            child: const HomePage(),
          ),
        );
      },
    );
  }
}
