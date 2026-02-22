import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
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
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/theme_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:upgrader/upgrader.dart';

import 'appAudioHandler.dart';
import 'constants.dart';
import 'firebase_options.dart';
import 'globals.dart' as globals;
import 'services/car_play_service.dart';
import 'services/image_cache_service.dart';
import 'services/quick_actions_service.dart';
import 'services/network_service.dart';
import 'services/station_data_service.dart';

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
      FirebaseCrashlytics.instance.recordError(e, stackTrace, fatal: false);
    }
  }
}

void main() async {
  PerformanceMonitor.markAppStart();

  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // Run Firebase init, Hive init, and SharedPreferences in parallel.
  // Firebase must complete before messaging, but Hive and prefs are independent.
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

  // Wait for Hive + prefs only — Firebase continues in background.
  // GraphQL and audio don't need Firebase, so we start them sooner.
  final hivePrefsResults = await Future.wait([hiveStoreFuture, prefsFuture]);
  final Store graphQlStore = hivePrefsResults[0] as Store;
  final SharedPreferences prefs = hivePrefsResults[1] as SharedPreferences;

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

  // Register SharedPreferences globally to avoid redundant getInstance() calls
  getIt.registerSingleton<SharedPreferences>(prefs);

  // Construct and register all services (sync, instant).
  // Registration must happen BEFORE AudioService.init() because the builder
  // callback creates AppAudioHandler which accesses GetIt<StationDataService>.
  final networkService = NetworkService();
  getIt.registerSingleton<NetworkService>(networkService);

  final imageCacheService = ImageCacheService();
  getIt.registerSingleton<ImageCacheService>(imageCacheService);

  final stationDataService = StationDataService(graphqlClient: graphqlClient);
  getIt.registerSingleton<StationDataService>(stationDataService);

  // NetworkService must be initialized before AudioService.init() because
  // AppAudioHandler's constructor subscribes to NetworkService.isOnMobileData
  // and needs the correct initial connectivity state.
  await networkService.initialize();

  // Start AudioService.init() early — it's the biggest blocker (500-1500ms).
  // It now runs in parallel with ImageCacheService + StationDataService init.
  final audioHandlerFuture = PerformanceMonitor.trackAsync('audio_service_init', () =>
    initAudioService(graphqlClient: graphqlClient),
  );
  final packageInfoFuture = PackageInfo.fromPlatform();

  // ImageCacheService initializes in parallel with AudioService.init()
  await PerformanceMonitor.trackAsync('image_cache_init', () => imageCacheService.initialize());

  // StationDataService after ImageCacheService (thumbnail pre-caching depends on it)
  await PerformanceMonitor.trackAsync('station_data_init', () => stationDataService.initialize());

  // Now await Firebase (likely already done since audio init takes longer)
  await firebaseInitFuture;

  // Firebase-dependent: error handlers, analytics, messaging
  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    developer.log('PlatformDispatcher.instance.onError', error: error, stackTrace: stack);
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  if (prefs.getBool('_notificationsEnabled') ?? true) {
    FirebaseAnalytics.instance.setUserProperty(name: 'personalized_n', value: 'true');
  }

  PerformanceMonitor.trackAsync('firebase_messaging_init', () => initializeFirebaseMessaging());

  // Wait for audio + packageInfo
  final serviceResults = await Future.wait([audioHandlerFuture, packageInfoFuture]);
  getIt.registerSingleton<AppAudioHandler>(serviceResults[0] as AppAudioHandler);

  final packageInfo = serviceResults[1] as PackageInfo;
  globals.appVersion = packageInfo.version;
  globals.buildNumber = packageInfo.buildNumber;

  // Non-blocking: get device ID for Crashlytics
  FirebaseInstallations.instance.getId().then((value) {
    globals.deviceId = value;
    FirebaseCrashlytics.instance.setUserIdentifier(globals.deviceId);
  });

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

  QuickActionsService.initialize();

  // Remove splash AFTER theme is ready to avoid blank screen flash
  FlutterNativeSplash.remove();

  runApp(const RadioCrestinApp());

  // Defer CarPlay/Android Auto init to after first frame (not needed for initial render)
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final carPlayService = await PerformanceMonitor.trackAsync('carplay_service_init', () async {
      final service = CarPlayService();
      await service.initialize();
      return service;
    });
    getIt.registerSingleton<CarPlayService>(carPlayService);
  });
}

class RadioCrestinApp extends StatelessWidget {
  const RadioCrestinApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeManager.themeMode,
      builder: (context, themeMode, child) {
        return MaterialApp(
          navigatorKey: globals.navigatorKey,
          title: 'Radio Crestin',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          home: UpgradeAlert(
        dialogStyle: Platform.isIOS ? UpgradeDialogStyle.cupertino : UpgradeDialogStyle.material,
        upgrader: Upgrader(),
        child: const HomePage(),
          ),
        );
      },
    );
  }
}
