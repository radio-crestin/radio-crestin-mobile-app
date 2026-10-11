import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/car_play_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/song_like_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_metadata_backend.dart';

/// End to end through a real [AppAudioHandler] (review gap 10): an audible
/// overlay change must reach the media session item (lock screen, CarPlay
/// Now Playing), the current station (Android Auto player, CarPlay lists)
/// and the "Recently played" queue (Android Auto), cut at the audible
/// instant. The player is never loaded; the timeline hooks are driven
/// directly.
/// No song is liked; the handler only reads like states here.
class _NoLikes extends Fake implements SongLikeService {
  @override
  int getLikeStatus(int songId) => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 10, 11, 12);
  DateTime t(num seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));

  late FakeClock clock;
  late FakeMetadataBackend backend;
  late StationDataService service;
  late AppAudioHandler handler;
  DateTime? audible;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    final prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    GetIt.instance.registerSingleton<PlayCountService>(PlayCountService());
    GetIt.instance.registerSingleton<SongLikeService>(_NoLikes());
    reviewsStatsCache.clear();
    clock = FakeClock(t0);
    backend = FakeMetadataBackend(clock)
      ..addStation(1, 'rve-suceava', 'RVE Suceava');
    for (var id = 2; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    backend.songChange(1, t(-300), const FakeSong(11, 'Song X', artist: 'AX'));
    backend.songChange(1, t(-60), const FakeSong(12, 'Song Y', artist: 'AY'));
    service = backend.newService(prefs);
    GetIt.instance.registerSingleton<StationDataService>(service);
  });

  tearDown(() async {
    service.dispose();
    await GetIt.instance.reset();
  });

  test(
      'an overlay change reaches mediaItem, the current station and the '
      'Android Auto queue', () async {
    await http.runWithClient(() async {
      handler = AppAudioHandler(
        graphqlClient: backend.graphqlClient,
        player: AudioPlayer(
          handleInterruptions: false,
          androidApplyAudioAttributes: false,
          handleAudioSessionActivation: false,
        ),
      );
      // The handler's own station hook stays; the timeline hooks are
      // driven by the test (no stream is loaded).
      service.isTimeShiftedHlsActive = () => true;
      service.getAudibleInstant = () => audible;
      await service.enqueueSync(SyncReason.startup);
      await handler
          .selectStation(service.stations.value.firstWhere((s) => s.id == 1));
      await clock.settle();
      expect(handler.mediaItem.value?.extras?['song_title'], 'Song Y',
          reason: 'live before the anchor');

      // Anchored 138 s behind live: Song X is audible, Song Y is not yet.
      audible = t(-138);
      await service.refreshMetadataNow();
      await clock.settle();

      MediaItem item = handler.mediaItem.value!;
      expect(item.extras?['song_title'], 'Song X');
      expect(item.artist, 'Song X • AX');
      expect(handler.currentStation.value?.songTitle, 'Song X');
      final car = CarPlayService.computePlayerFields(
        inPlaylistMode: false,
        playlistItemTitle: null,
        playlistItemImageUrl: null,
        stationTitle: handler.currentStation.value!.title,
        stationSongTitle: handler.currentStation.value!.songTitle,
        stationSongArtist: handler.currentStation.value!.songArtist,
        stationThumbnailUrl: null,
      );
      expect(car.songTitle, 'Song X');
      expect(handler.queue.value.map((i) => i.title), ['Song X'],
          reason: 'Song Y is still ahead of the audible instant');

      // The audible instant reaches Song Y's boundary.
      audible = t(-50);
      await service.refreshMetadataNow(boundary: t(-60));
      await clock.settle();

      item = handler.mediaItem.value!;
      expect(item.extras?['song_title'], 'Song Y');
      expect(handler.currentStation.value?.songTitle, 'Song Y');
      expect(handler.queue.value.map((i) => i.title), ['Song Y', 'Song X']);

      // Leaving time-shifted playback shows the live song again.
      backend.songChange(1, t(5), const FakeSong(13, 'Song Z'));
      await clock.advance(const Duration(seconds: 60));
      await service.enqueueSync(SyncReason.periodic);
      expect(handler.mediaItem.value?.extras?['song_title'], 'Song Y');
      service.onAlignedPlaybackEnded();
      await clock.settle();
      expect(handler.mediaItem.value?.extras?['song_title'], 'Song Z');
    }, () => backend.client);
  });
}
