import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/analytics_service.dart';
import 'package:radio_crestin/services/hls_health_watchdog_flag.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_just_audio_channels.dart';
import 'helpers/fake_metadata_backend.dart';
import 'helpers/station_factory.dart';

/// No song is liked; the handler only reads like states here.
class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

/// Android Auto rebuilds a folder's list on every change it is told about,
/// which can move the list away from where the driver scrolled. Only a
/// change to what the folder shows may reach it; the songs under the
/// stations stay live, as on CarPlay.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 10, 11, 12);
  DateTime t(num seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));

  const root = AudioService.browsableRootId;
  const favoritesTab = 'favoriteStationsRootId';
  const allStationsTab = 'allStationsRootId';
  const categoriesTab = 'categoriesRootId';
  const copii = 'group:copii';

  const songA = FakeSong(31, 'Song A', artist: 'Artist A');

  late SharedPreferences prefs;
  late FakeClock clock;
  late FakeMetadataBackend backend;
  late FakeJustAudioChannels channels;
  late StationDataService service;
  late AppAudioHandler handler;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    prefs = await SharedPreferences.getInstance();
    await HlsHealthWatchdogFlag.instance.loadCache(prefs);
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<SharedPreferences>(prefs)
      ..registerSingleton<PlayCountService>(PlayCountService())
      ..registerSingleton<SongLikeService>(_NoLikes())
      ..registerSingleton<VideoPlaybackService>(VideoPlaybackService());
    reviewsStatsCache.clear();
    clock = FakeClock(t0);
    backend = FakeMetadataBackend(clock);
    // The service only accepts a catalog of at least 10 stations.
    for (var id = 1; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    backend.songChange(3, t(-100), songA);
    channels = FakeJustAudioChannels()..install();
  });

  tearDown(() async {
    await http.runWithClient(() => handler.stop(), () => backend.client);
    AnalyticsService.instance.endListening();
    service.dispose();
    channels.uninstall();
    await GetIt.instance.reset();
  });

  /// Runs [body] with the backend as the app's HTTP client.
  Future<void> withBackend(Future<void> Function() body) =>
      http.runWithClient(body, () => backend.client);

  /// Starts the handler and, when [sync], loads the stations.
  Future<void> startHandler({bool sync = true}) async {
    service = backend.newService(prefs);
    GetIt.instance.registerSingleton<StationDataService>(service);
    handler = AppAudioHandler(
      graphqlClient: backend.graphqlClient,
      player: AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
        handleAudioSessionActivation: false,
      ),
    );
    if (sync) await service.enqueueSync(SyncReason.startup);
  }

  Station stationOf(int id) =>
      service.stations.value.firstWhere((s) => s.id == id);

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not met in 5 s');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// The station [slug] as the handler publishes it to Android Auto.
  MediaItem publishedOf(String slug) => handler.stationsMediaItems.value
      .firstWhere((i) => i.extras?['station_slug'] == slug);

  /// The poll a minute later, as the app runs it.
  Future<void> poll() async {
    await clock.advance(const Duration(seconds: 60));
    unawaited(service.enqueueSync(SyncReason.periodic));
  }

  /// The reloads Android Auto is asked for in [folder] after it subscribed
  /// (each subscription starts with one, its seed).
  Future<List<Object?>> changesOf(String folder) async {
    final events = <Object?>[];
    final sub = handler.subscribeToChildren(folder).listen(events.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(events, hasLength(1), reason: 'only the seed');
    events.clear();
    return events;
  }

  Future<List<String>> titlesIn(String folder) async =>
      [for (final row in await handler.getChildren(folder)) row.title];

  /// The "Copii" category and the API's group of every station, which the
  /// car leaves out.
  void addCopii() => backend
    ..addGroup(1, 'toate', 'Toate', [for (var id = 1; id <= 10; id++) id])
    ..addGroup(2, 'copii', 'Copii', [3, 5, 7]);

  test('a poll that changes nothing the car shows reloads no folder',
      () async {
    addCopii();
    await withBackend(() async {
      await startHandler();
      await service.setStationIsFavorite(stationOf(3), true);
      final changes = {
        for (final folder in [
          root,
          favoritesTab,
          allStationsTab,
          categoriesTab,
          copii,
        ])
          folder: await changesOf(folder),
      };

      // Only the listener count of the favorite changes.
      backend.listenerReport(3, t(30),
          song: songA, songStartedAt: t(-100), listeners: 42);
      await poll();
      await until(() => publishedOf('s3').extras?['total_listeners'] == 42);
      await pumpEventQueue();

      expect({for (final e in changes.entries) e.key: e.value.length},
          {for (final folder in changes.keys) folder: 0});
    });
  });

  test(
      'a song change reloads only the Favorite tab, when the station is a '
      'favorite; Toate stațiile and the categories show no songs', () async {
    addCopii();
    backend.songChange(5, t(-100), const FakeSong(51, 'Song B'));
    await withBackend(() async {
      await startHandler();
      await service.setStationIsFavorite(stationOf(3), true);
      final rootChanges = await changesOf(root);
      final favorites = await changesOf(favoritesTab);
      final all = await changesOf(allStationsTab);
      final category = await changesOf(copii);

      backend.songChange(5, t(30), const FakeSong(52, 'Song C'));
      await poll();
      await until(() => publishedOf('s5').displaySubtitle == 'Song C');
      await pumpEventQueue();
      expect(favorites, isEmpty, reason: 'Station 5 is no favorite');

      backend.songChange(3, t(90), const FakeSong(32, 'Song N', artist: 'N'));
      await poll();
      await until(() => favorites.isNotEmpty);
      final favoriteRows = await handler.getChildren(favoritesTab);
      expect(favoriteRows.single.displaySubtitle, 'Song N • N');

      await pumpEventQueue();
      expect(all, isEmpty, reason: 'its rows show no song');
      expect(category, isEmpty, reason: 'its rows show no song');
      expect(rootChanges, isEmpty);

      // What they do show still reloads them: here the star of a new
      // favorite.
      await service.setStationIsFavorite(stationOf(5), true);
      await until(() => all.isNotEmpty && category.isNotEmpty);
    });
  });

  test(
      'the root tabs stay put through station data and favorites, and '
      'reload when Categorii comes', () async {
    await withBackend(() async {
      await startHandler();
      final changes = await changesOf(root);
      expect(await titlesIn(root), ['Favorite', 'Toate stațiile']);

      backend.songChange(3, t(30), const FakeSong(32, 'Song N'));
      await poll();
      await until(() => publishedOf('s3').displaySubtitle == 'Song N');
      await service.setStationIsFavorite(stationOf(3), true);
      await pumpEventQueue();
      expect(changes, isEmpty);

      service.stationGroups.add([
        for (final (id, slug, stationIds) in [
          (1, 'toate', [for (var id = 1; id <= 10; id++) id]),
          (2, 'copii', [3, 5]),
        ])
          StationFactory.createStationGroup(
            id: id,
            name: slug,
            slug: slug,
            stationToStationGroups: [
              for (final stationId in stationIds)
                StationFactory.createStationToStationGroup(
                    stationId: stationId),
            ],
          ),
      ]);
      await until(() => changes.isNotEmpty);
      await pumpEventQueue();
      expect(changes, hasLength(1));
      expect(
          await titlesIn(root), ['Favorite', 'Toate stațiile', 'Categorii']);
    });
  });

  test(
      'a favorite reads "Name ★" where it mixes with other stations, and '
      'its row still plays it', () async {
    addCopii();
    await withBackend(() async {
      await startHandler();
      final all = await changesOf(allStationsTab);
      await service.setStationIsFavorite(stationOf(3), true);
      await until(() => all.isNotEmpty);

      final row = (await handler.getChildren(allStationsTab))
          .firstWhere((i) => i.extras?['station_slug'] == 's3');
      expect((row.title, row.displayTitle), ('Station 3 ★', 'Station 3 ★'),
          reason: "Android Auto's A·Z index files it under S, not #");
      expect(
          await titlesIn(copii), ['Station 3 ★', 'Station 5', 'Station 7']);
      expect(await titlesIn(favoritesTab), ['Station 3']);

      expect(row.extras?.keys.toSet(),
          {'android.media.extra.SORT_KEY', 'station_id', 'station_slug'},
          reason: 'only what the car or playMediaItem reads');
      expect(publishedOf('s3').extras, contains('station_streams'),
          reason: 'search and playFromMediaId keep every extra');

      unawaited(handler.playFromMediaId(row.id));
      await until(() =>
          handler.currentStreamInfo.valueOrNull?.url ==
              FakeMetadataBackend.mp3UrlOf('s3') &&
          handler.player.playing);
    });
  });

  test(
      'the Favorite tab fills in when the stations load after it, and '
      'drops a favorite that is hidden', () async {
    await withBackend(() async {
      await startHandler(sync: false);
      service.favoriteStationSlugs.add(['s3']);
      final changes = await changesOf(favoritesTab);
      expect(await handler.getChildren(favoritesTab), isEmpty);

      await service.enqueueSync(SyncReason.startup);
      await until(() => changes.isNotEmpty);
      expect(await titlesIn(favoritesTab), ['Station 3']);

      changes.clear();
      handler.hideStation(stationOf(3));
      await until(() => changes.isNotEmpty);
      expect(await handler.getChildren(favoritesTab), isEmpty);
    });
  });
}
