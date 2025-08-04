import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

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

import 'appAudioHandler.dart';
import 'constants.dart';
import 'firebase_options.dart';
import 'globals.dart' as globals;

final getIt = GetIt.instance;

Future<void> initializeFirebaseMessaging() async {
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
    final fcmToken = await FirebaseMessaging.instance.getToken();
    developer.log("FCMToken $fcmToken");
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

  final remoteConfig = FirebaseRemoteConfig.instance;
  await remoteConfig.setConfigSettings(RemoteConfigSettings(
    fetchTimeout: const Duration(minutes: 0),
    minimumFetchInterval: const Duration(hours: 1),
  ));

  await remoteConfig.setDefaults(const {
    "share_app_message": "Aplicația Radio Creștin:\nhttps://share.radiocrestin.ro",
    "share_app_station_message": "Ascultă și tu ",
  });

  remoteConfig.fetchAndActivate();

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

  getIt.registerSingleton<AppAudioHandler>(await initAudioService(graphqlClient: graphqlClient));

  PackageInfo.fromPlatform().then((value) {
    globals.appVersion = value.version;
    globals.buildNumber = value.buildNumber;
  });

  FirebaseInstanceId.appInstanceId.then((value) {
    globals.deviceId = value ?? "";
    FirebaseCrashlytics.instance.setUserIdentifier(globals.deviceId);
  });

  FlutterNativeSplash.remove();

  await ThemeManager.initialize();
  
  runApp(const RadioCrestinApp());
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
