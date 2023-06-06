import 'package:fast_cached_network_image/fast_cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'constants.dart';
import 'appAudioHandler.dart';


final getIt = GetIt.instance;

void main() async {

  await FastCachedImageConfig.init(clearCacheAfter: const Duration(days: 30));

  // We're using HiveStore for persistence,
  // so we need to initialize Hive.
  await initHiveForFlutter();

  final HttpLink httpLink = HttpLink(
    CONSTANTS.GRAPHQL_ENDPOINT,
  );

  final AuthLink authLink = AuthLink(
    getToken: () async => CONSTANTS.GRAPHQL_AUTH,
  );

  final Link graphqlLink = authLink.concat(httpLink);

  // The default store is the InMemoryStore, which does NOT persist to disk
  final graphQlCache = GraphQLCache(store: HiveStore());

  GraphQLClient graphqlClient = GraphQLClient(
    link: graphqlLink,
    cache: graphQlCache,
  );
  final audioPlayer = AudioPlayer(
    // userAgent: 'radiocrestinapp/1.0 (Linux;Android 11) https://www.radio-crestin.com',
  );

  getIt.registerSingleton<AppAudioHandler>(await initAudioService(audioPlayer: audioPlayer, graphqlClient: graphqlClient));


  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider(
          create: (_) => getIt<AppAudioHandler>()),
    ],
    child: RadioCrestinApp(),
  ));

}

class RadioCrestinApp extends StatelessWidget {
  const RadioCrestinApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radio Crestin',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
