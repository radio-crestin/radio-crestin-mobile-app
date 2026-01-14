import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_instance_id/firebase_instance_id.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/graphql_to_rest_interceptor.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/theme_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:upgrader/upgrader.dart';
import 'package:provider/provider.dart';
import 'package:flutter_mobx/flutter_mobx.dart';

import 'appAudioHandler.dart';
import 'components/NotificationBanner.dart';
import 'constants.dart';
import 'firebase_options.dart';
import 'globals.dart' as globals;
import 'stores/app_settings_store.dart';

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
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await initializeFirebaseMessaging();

  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
  };
  // Pass all uncaught asynchronous errors that aren't handled by the Flutter framework to Crashlytics
  PlatformDispatcher.instance.onError = (error, stack) {
    developer.log('PlatformDispatcher.instance.onError', error: error, stackTrace: stack);
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  final prefs = await SharedPreferences.getInstance();

  if (prefs.getBool('_notificationsEnabled') ?? true) {
    FirebaseAnalytics.instance.setUserProperty(name: 'personalized_n', value: 'true');
  }

  if (prefs.getString('_reviewStatus') == null) {
    var defaultReviewStatus = {
      'review_completed': false, // is completed when the user clicks on "5 stele" to add a review.
      'actions_made': 0,
    };

    prefs.setString('_reviewStatus', json.encode(defaultReviewStatus));
  }

  // We're using HiveStore for persistence,
  // so we need to initialize Hive.
  await initHiveForFlutter();

  final HttpLink httpLink = HttpLink(
    CONSTANTS.GRAPHQL_ENDPOINT,
  );

  final AuthLink authLink = AuthLink(
    getToken: () async => CONSTANTS.GRAPHQL_AUTH,
  );

  // Configure query-to-REST mappings
  final queryToRestMap = createGraphQLToRestMappings();

  final graphqlToRestInterceptor = GraphQLToRestInterceptorLink(
    queryToRestMap: queryToRestMap,
  );
  
  final Link graphqlLink = graphqlToRestInterceptor.concat(authLink.concat(httpLink));

  // The default store is the InMemoryStore, which does NOT persist to disk
  final graphQlCache = GraphQLCache(store: HiveStore());

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

  await ThemeManager.initialize();
  
  final appStore = AppStore();
  await appStore.initConnectivity();
  globals.appStore = appStore;

  final audioHandler = await initAudioService(graphqlClient: graphqlClient);
  getIt.registerSingleton<AppAudioHandler>(audioHandler);
  
  // Set up callback to start playback when internet connection is restored
  appStore.onConnectivityRestored = () async {
    // Check if we have a current station
    if (audioHandler.currentStation.valueOrNull != null) {
      // Get current playback state
      final playbackState = audioHandler.playbackState.valueOrNull;
      final isBuffering = playbackState?.processingState == AudioProcessingState.buffering;
      
      // Check if app is in foreground
      final appLifecycleState = WidgetsBinding.instance.lifecycleState;
      final isAppVisible = appLifecycleState == AppLifecycleState.resumed;
      
      // Resume playback if either buffering or app is visible
      if (isBuffering || isAppVisible) {
        await audioHandler.play();
      }
    }
  };

  PackageInfo.fromPlatform().then((value) {
    globals.appVersion = value.version;
    globals.buildNumber = value.buildNumber;
  });

  FirebaseInstanceId.appInstanceId.then((value) {
    globals.deviceId = value ?? "";
    FirebaseCrashlytics.instance.setUserIdentifier(globals.deviceId);
  });

  FlutterNativeSplash.remove();
  
  runApp(RadioCrestinApp(appStore: appStore));
}

class RadioCrestinApp extends StatelessWidget {
  final AppStore appStore;
  
  const RadioCrestinApp({super.key, required this.appStore});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return Provider<AppStore>(
      create: (_) => appStore,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: ThemeManager.themeMode,
        builder: (context, themeMode, child) {
          return MaterialApp(
            navigatorKey: globals.navigatorKey,
            title: 'Radio Crestin',
            debugShowCheckedModeBanner: false,
            theme: lightTheme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            builder: (context, child) {
              return Observer(
                builder: (_) {
                  final appStore = Provider.of<AppStore>(context);
                  final shouldShowBanner = appStore.showNotification;
                  
                  return Stack(
                    children: [
                      child!,
                      if (shouldShowBanner)
                        NotificationBanner(
                          key: const ValueKey('notification_banner'),
                          notificationType:
                              appStore.currentNotificationType ??
                              NotificationType.network,
                          message: appStore.currentNotificationMessage,
                          onDismiss: () => appStore.clearNotification(),
                        ),
                    ],
                  );
                },
              );
            },
            home: UpgradeAlert(
              dialogStyle: Platform.isIOS ? UpgradeDialogStyle.cupertino : UpgradeDialogStyle.material,
              upgrader: Upgrader(),
              child: const HomePage(),
            ),
          );
        },
      ),
    );
  }
}
