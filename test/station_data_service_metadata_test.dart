import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:radio_crestin/graphql_rest_mappings.dart';
import 'package:radio_crestin/services/audible_song_policy.dart';
import 'package:radio_crestin/services/hls_timeline.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/private_stations_service.dart';
import 'package:radio_crestin/services/song_history_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_metadata_backend.dart';
import 'helpers/hls_fixtures.dart' show playlistText;

/// Drives the production [StationDataService] against a fake backend, edge
/// cache and ingestion lag, with controlled time (client-metadata spec §5.2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A 10 s multiple, so the live timestamps are easy to read.
  final t0 = DateTime.utc(2026, 10, 11, 12);
  DateTime t(num seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));
  int epochOf(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
  const minute = Duration(seconds: 60);
  const twoMin = Duration(seconds: 120);

  const x = FakeSong(11, 'Song X', artist: 'Artist X');
  const y = FakeSong(12, 'Song Y', artist: 'Artist Y');
  const n = FakeSong(13, 'Song N', artist: 'Artist N');
  const z = FakeSong(14, 'Song Z');
  const jingle = FakeSong(15, 'Jingle');
  const p = FakeSong(21, 'Song P');
  const q = FakeSong(22, 'Song Q');

  late SharedPreferences prefs;
  late FakeClock clock;
  late FakeMetadataBackend backend;
  late FakePlayer player;
  StationDataService? current;

  StationDataService service() => current!;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'station_sort_preference': 'alphabetical',
    });
    prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
    GetIt.instance.registerSingleton<PlayCountService>(PlayCountService());
    reviewsStatsCache.clear();
    clock = FakeClock(t0);
    backend = FakeMetadataBackend(clock)
      ..addStation(1, 'rve-suceava', 'RVE Suceava');
    for (var id = 2; id <= 10; id++) {
      backend.addStation(id, 's$id', 'Station $id');
    }
    player = FakePlayer(clock);
    current = null;
  });

  tearDown(() async {
    current?.dispose();
    await GetIt.instance.reset();
  });

  /// Builds the service and runs the startup sync at the current time.
  Future<StationDataService> start() async {
    final s = backend.newService(prefs);
    player.attach(s);
    current = s;
    await s.enqueueSync(SyncReason.startup);
    return s;
  }

  Station stationOf(int id) =>
      service().stations.value.firstWhere((s) => s.id == id);
  String songOf(int id) => stationOf(id).songTitle;

  /// Starts [future] and lets it run for [elapse] of fake time.
  Future<void> drive(Future<void> future,
      [Duration elapse = Duration.zero]) async {
    unawaited(future);
    await clock.advance(elapse);
  }

  /// One 60 s periodic tick.
  Future<void> tick() async {
    await clock.advance(minute);
    await drive(service().enqueueSync(SyncReason.periodic));
  }

  int toOf(Uri url) => int.parse(url.queryParameters['to_timestamp']!);
  int fromOf(Uri url) => int.parse(url.queryParameters['from_timestamp']!);

  group('live sync', () {
    test('periodic diff leaves stations absent from the diff unchanged',
        () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(2, t(-300), p);
      await start();
      backend.songChange(2, t(30), q);

      await tick();

      expect(songOf(2), 'Song Q');
      expect(songOf(1), 'Song X');
      expect(backend.metadataRequests.last.queryParameters,
          containsPair('changes_from_timestamp', '${epochOf(t(-60))}'));
    });

    test('diff requests changes_from = cursor - 60s (overlap)', () async {
      await start();
      await tick();

      final url = backend.metadataRequests.last;
      expect(url.queryParameters['timestamp'], '${epochOf(t(60))}');
      expect(
          url.queryParameters['changes_from_timestamp'], '${epochOf(t(-60))}');
    });

    test(
        'a back-dated row inserted after a diff is delivered by the next '
        'diff', () async {
      backend.songChange(2, t(-300), p);
      await start();
      // Dated before the t+60 diff, ingested just after it.
      backend.songChange(2, t(55), q, insertedAt: t(65));

      await tick();
      expect(songOf(2), 'Song P');
      await tick();
      expect(songOf(2), 'Song Q');
    });

    test('failed diff does not advance the cursor', () async {
      await start();
      backend.failNext('/stations-metadata');
      await tick();
      await tick();

      final url = backend.metadataRequests.last;
      expect(url.queryParameters['timestamp'], '${epochOf(t(120))}');
      expect(
          url.queryParameters['changes_from_timestamp'], '${epochOf(t(-60))}');
    });

    test('full refresh advances the cursor only when metadata succeeded',
        () async {
      await start();
      await clock.advance(minute);
      backend.failNext('/stations-metadata');
      await service().refreshStations();
      await tick();
      expect(backend.metadataRequests.last.queryParameters,
          containsPair('changes_from_timestamp', '${epochOf(t(-60))}'));

      await clock.advance(const Duration(seconds: 10));
      await service().refreshStations(); // live timestamp t+130
      await tick();
      expect(backend.metadataRequests.last.queryParameters,
          containsPair('changes_from_timestamp', '${epochOf(t(70))}'));
    });

    test('a diff with the same parameters as the last one is not sent again',
        () async {
      await start();
      await service().onStationPlayed();
      await service().onStationPlayed();
      await service().enqueueSync(SyncReason.liveMetadataChanged);

      expect(backend.metadataRequests, hasLength(2),
          reason: 'startup + one diff: the edge answers the same request '
              'with the same copy');

      await clock.advance(const Duration(seconds: 10));
      await service().onStationPlayed();
      expect(backend.metadataRequests, hasLength(3),
          reason: 'a new timestamp is a new request');
    });

    test(
        'the same timestamp from a newer cursor is sent: it can carry a row '
        'ingested since', () async {
      backend.songChange(2, t(-300), p);
      await start();
      await clock.advance(minute);
      // Dated before the t+60 diff, ingested just after it.
      backend.songChange(2, t(55), q, insertedAt: t(62));
      await service().onStationPlayed();
      expect(songOf(2), 'Song P');

      await clock.advance(const Duration(seconds: 5));
      await service().onStationPlayed();

      expect(songOf(2), 'Song Q');
      expect(backend.metadataRequests.last.queryParameters, {
        'timestamp': '${epochOf(t(60))}',
        'changes_from_timestamp': '${epochOf(t0)}',
      });
    });

    test('a failed diff is sent again with the same parameters', () async {
      await start();
      backend.failNext('/stations-metadata');
      await service().onStationPlayed();
      await service().onStationPlayed();

      final diffs = backend.metadataRequests.skip(1).toList();
      expect(diffs, hasLength(2));
      expect(diffs.last, diffs.first);
    });

    test('a full refresh lets the next diff go out even with the same '
        'parameters', () async {
      await start();
      await service().onStationPlayed();
      await service().refreshStations();
      await service().onStationPlayed();

      final diffs = backend.metadataRequests
          .where((u) => u.queryParameters
              .containsKey('changes_from_timestamp'))
          .toList();
      expect(diffs, hasLength(2));
      expect(diffs.last, diffs.first);
    });

    test('GraphQL failure still applies live metadata', () async {
      backend.songChange(2, t(-300), p);
      await start();
      backend.songChange(2, t(30), q);
      await clock.advance(minute);
      backend.failNext('/graphql');

      await service().refreshStations();

      expect(songOf(2), 'Song Q');
    });
  });

  group('aligned overlay', () {
    test('anchored refresh resolves the history row at the audible instant',
        () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      backend.songChange(2, t(-300), p);
      await start();
      expect(songOf(1), 'Song Y', reason: 'live before the anchor');

      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());

      expect(songOf(1), 'Song X');
      expect(songOf(2), 'Song P', reason: 'other stations stay live');
      final url = backend.historyRequests.single;
      expect(url.queryParameters['station_slug'], 'rve-suceava');
      expect(toOf(url), epochOf(t(-130)), reason: 'ceil10(A)');
      expect(fromOf(url), epochOf(t(-130)) - 3600);
    });

    test(
        'anchored refresh uses the live list without a request when it '
        'proves the audible song', () async {
      backend.songChange(1, t(-300), x);
      await start();

      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());

      expect(songOf(1), 'Song X');
      expect(backend.historyRequests, isEmpty);
    });

    test(
        'anchored refresh with a null audible instant does nothing (no '
        'live fallback)', () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player
        ..playingId = 1
        ..active = true;

      await drive(service().refreshMetadataNow());

      expect(backend.historyRequests, isEmpty);
      expect(backend.metadataRequests, hasLength(1));
      expect(songOf(1), 'Song Y');
    });

    test(
        'live diff and full refresh never overwrite the aligned station\'s '
        'song; its listeners and uptime still update', () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());
      backend.songChange(1, t(30), z, listeners: 99);

      await tick();
      expect(songOf(1), 'Song X');
      expect(stationOf(1).totalListeners, 99);
      expect(stationOf(1).isUp, isTrue);

      await clock.advance(const Duration(seconds: 10));
      await service().refreshStations();
      expect(songOf(1), 'Song X');
      expect(stationOf(1).totalListeners, 99);
    });

    test(
        'boundary uses the live row starting within ±1.5 s of B without a '
        'request', () async {
      final b = t(-100);
      backend.songChange(1, t(-300), x);
      backend.songChange(1, b.add(const Duration(milliseconds: 600)), n);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());
      expect(songOf(1), 'Song X');

      await clock.advance(const Duration(seconds: 40));
      await drive(service().refreshMetadataNow(boundary: b));

      expect(songOf(1), 'Song N');
      expect(backend.historyRequests, hasLength(1),
          reason: 'only the anchor queried history');
    });

    test(
        'a live row at B+8 is not accepted: history gives the first row in '
        'the window', () async {
      final b = t(-100);
      backend.songChange(1, t(-300), x);
      backend.songChange(1, b, n);
      backend.songChange(1, b.add(const Duration(seconds: 8)), jingle);
      await start();
      player.playHls(1, const Duration(seconds: 90));

      await drive(service().refreshMetadataNow(boundary: b));

      expect(songOf(1), 'Song N');
      final url = backend.historyRequests.single;
      expect(fromOf(url), epochOf(b) - 2);
      expect(toOf(url), epochOf(b) + 20);
    });

    test(
        'a row stamped 10.6 s after the boundary (radio-eldad) is the '
        'change row', () async {
      final b = t(-100);
      backend.songChange(1, t(-300), x);
      backend.songChange(1, b.add(const Duration(milliseconds: 10600)), n);
      await start();
      player.playHls(1, const Duration(seconds: 90));

      await drive(service().refreshMetadataNow(boundary: b));

      expect(songOf(1), 'Song N');
    });

    test('equal-timestamp tie applies the last tied row in API order (B3)',
        () async {
      final b = t(-100);
      backend.songChange(1, t(-300), x);
      backend.songChange(1, b, const FakeSong(31, 'Un radio de Cuvant'));
      backend.songChange(1, b, const FakeSong(32, 'Scraped song'));
      backend.songChange(1, b.add(const Duration(seconds: 25)), y);
      await start();
      player.playHls(1, const Duration(seconds: 90));

      await drive(service().refreshMetadataNow(boundary: b));

      expect(songOf(1), 'Scraped song');
    });

    test(
        'boundary retries with a new to_timestamp when the edge copy '
        'predates ingestion (C4)', () async {
      backend.historyMaxAge = twoMin; // copies stacked across layers
      final b = t(10);
      final bs = epochOf(b);
      backend.songChange(1, t(-300), x);
      backend.songChange(1, b, n,
          insertedAt: b.add(const Duration(seconds: 30)));
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      expect(songOf(1), 'Song X');

      // An instant-mode listener freezes the shared key before ingestion.
      await clock.advance(const Duration(seconds: 35));
      await backend.client.get(Uri.parse(
          'https://api.radiocrestin.ro/api/v1/stations-metadata-history'
          '?station_slug=rve-suceava&from_timestamp=${bs - 2}'
          '&to_timestamp=${bs + 20}'));

      await clock.advance(const Duration(seconds: 95));
      await drive(service().refreshMetadataNow(boundary: b));
      expect(songOf(1), 'Song X', reason: 'the frozen copy lacks the row');
      await clock.advance(const Duration(seconds: 3));

      expect(songOf(1), 'Song N');
      final ours = backend.historyRequests.skip(1).toList();
      expect(ours.map(toOf), [bs + 20, bs + 21]);
    });

    test(
        'a settled response without a change row ends the lookup after one '
        'request', () async {
      final b = t(10);
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(boundary: b), twoMin);

      expect(backend.historyRequests, hasLength(1));
      expect(songOf(1), 'Song X');
    });

    test(
        'a response without Last-Modified is never settled: the retry '
        'budget decides (R11)', () async {
      backend.sendLastModified = false;
      final b = t(10);
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(boundary: b), twoMin);

      expect(backend.historyRequests, hasLength(5));
      expect(songOf(1), 'Song X');
    });

    test('gives up after 5 attempts and keeps the previous title', () async {
      final b = t(10);
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      backend.failNext('-history', count: 10);
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(boundary: b),
          const Duration(minutes: 3));

      expect(backend.historyRequests, hasLength(5));
      expect(songOf(1), 'Song X');
    });

    test('newer boundary supersedes an older in-flight resolution', () async {
      final b1 = t(10);
      final b2 = t(20);
      backend.songChange(1, t(-300), x);
      backend.songChange(1, b1, n);
      backend.songChange(1, b2, y);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      backend.beforeHistoryResponse = (url) async {
        if (fromOf(url) == epochOf(b1) - 2) {
          await clock.wait(const Duration(seconds: 20));
        }
      };
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(boundary: b1));
      await clock.advance(const Duration(seconds: 10));
      await drive(service().refreshMetadataNow(boundary: b2));
      expect(songOf(1), 'Song Y');

      await clock.advance(const Duration(seconds: 30));
      expect(songOf(1), 'Song Y', reason: 'the late B1 answer is dropped');
    });

    test('re-anchor to a larger offset moves the title back to an older song',
        () async {
      backend.songChange(1, t(-600), x);
      backend.songChange(1, t(-200), y);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      expect(songOf(1), 'Song Y');

      player.playHls(1, const Duration(seconds: 300));
      await drive(service().refreshMetadataNow());

      expect(songOf(1), 'Song X');
    });

    test(
        'onAlignedPlaybackEnded reverts the station to its live song '
        'immediately and cancels retries', () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());
      expect(songOf(1), 'Song X');
      backend.failNext('-history', count: 10);
      await drive(service().refreshMetadataNow(boundary: t(-130)));
      final requests = backend.historyRequests.length;

      service().onAlignedPlaybackEnded();

      expect(songOf(1), 'Song Y');
      await clock.advance(const Duration(minutes: 2));
      expect(backend.historyRequests, hasLength(requests));
    });

    test(
        'B14 hint with a song id is applied with zero requests; a '
        'title-only hint is ignored', () async {
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(
        boundary: t(10),
        hint: const SongBoundaryHint(
          songId: 77,
          title: 'Hinted',
          artist: 'Artist H',
          thumbnailUrl: 'https://cdn.example.com/h.webp',
        ),
      ));
      expect(songOf(1), 'Hinted');
      expect(stationOf(1).songArtist, 'Artist H');
      expect(stationOf(1).songId, 77);
      expect(backend.historyRequests, isEmpty);

      await drive(service().refreshMetadataNow(
        boundary: t(12),
        hint: const SongBoundaryHint(title: 'ICY text only'),
      ));
      expect(backend.historyRequests, hasLength(1));
      expect(songOf(1), isNot('ICY text only'));
    });

    test('private or unknown station is never aligned (no history call)',
        () async {
      await start();
      player.playHls(999, twoMin);

      await drive(service().refreshMetadataNow(), minute);
      await drive(service().refreshMetadataNow(boundary: t(-130)), minute);

      expect(backend.historyRequests, isEmpty);
    });

    test('result for a station that is no longer playing is dropped (C11)',
        () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      backend.beforeHistoryResponse =
          (_) => clock.wait(const Duration(seconds: 10));
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());

      player.playingId = 2; // switched before the answer arrived
      await clock.advance(const Duration(seconds: 10));
      player.playingId = 1;
      backend.songChange(1, t(15), y, listeners: 42);
      await tick();

      expect(stationOf(1).totalListeners, 42, reason: 'republished');
      expect(songOf(1), 'Song Y', reason: 'no overlay was stored');
    });

    test('the overlay shows only while its station is the playing one',
        () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());
      expect(songOf(1), 'Song X');

      player.playingId = 2; // switched; the end call has not arrived yet
      backend.songChange(1, t(15), y, listeners: 42);
      await tick();

      expect(songOf(1), 'Song Y');
      player.playingId = 1;
      backend.songChange(1, t(75), y, listeners: 43);
      await tick();
      expect(songOf(1), 'Song X', reason: 'same station again: kept');
    });

    test(
        'a resolution that completes right after onAlignedPlaybackEnded is '
        'not applied', () async {
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await clock.advance(const Duration(seconds: 130));

      // The hint resolves without I/O; the end call lands before the
      // resolution's continuation runs (the station stays current on stop).
      unawaited(service().refreshMetadataNow(
          boundary: t(10),
          hint: const SongBoundaryHint(songId: 77, title: 'Hinted')));
      service().onAlignedPlaybackEnded();
      await clock.settle();

      expect(songOf(1), 'Song X');
      expect(service().playedCutoffFor(1), clock.now.subtract(twoMin));
    });

    test(
        'periodic tick repairs a missed boundary from the live list without '
        'a request', () async {
      backend.songChange(1, t(-400), x);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());
      expect(songOf(1), 'Song X');
      // A song change whose boundary the playlist never announced.
      backend.songChange(1, t(-30), y, insertedAt: t(5));

      await tick(); // live list gets Y; A = t-78 has not reached it
      expect(songOf(1), 'Song X');
      await tick(); // A = t-18: the live list proves Y is audible

      expect(songOf(1), 'Song Y');
      expect(backend.historyRequests, isEmpty);
    });

    test(
        'safety net re-anchors after 5 min without a resolution, never while '
        'one is in flight', () async {
      backend.songChange(1, t(-600), x);
      backend.songChange(1, t(-100), y);
      await start();
      player.playHls(1, const Duration(seconds: 318));
      await drive(service().refreshMetadataNow());
      expect(backend.historyRequests, hasLength(1));
      player.pause(); // A frozen: the live list never proves a newer song

      for (var i = 0; i < 4; i++) {
        await tick();
      }
      expect(backend.historyRequests, hasLength(1));
      await tick(); // 5 min after the last resolution
      expect(backend.historyRequests, hasLength(2));
      expect(songOf(1), 'Song X');

      // A change whose answer is still in flight makes the resolver busy.
      backend.beforeHistoryResponse =
          (_) => clock.wait(const Duration(minutes: 30));
      await drive(service().refreshMetadataNow(boundary: t(-280)));
      final requests = backend.historyRequests.length;
      for (var i = 0; i < 6; i++) {
        await tick();
      }
      final anchors = backend.historyRequests
          .skip(requests)
          .where((u) => toOf(u) - fromOf(u) == 3600);
      expect(anchors, isEmpty);
    });

    test(
        'a station without an audible song yet (no anchored refresh, as on '
        'Windows/Linux) is resolved by the next tick', () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      expect(songOf(1), 'Song Y', reason: 'live: not heard yet');

      await tick(); // A = t-78

      expect(songOf(1), 'Song X');
      expect(backend.historyRequests, hasLength(1));
    });

    test(
        'a failed first anchor is retried by the tick after 5 min, not '
        'before', () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      player.pause(); // A frozen at t-138: the live list never proves Y
      backend.failNext('-history', count: 5);
      await drive(service().refreshMetadataNow(), minute);
      expect(songOf(1), 'Song Y');
      expect(backend.historyRequests, hasLength(5));

      for (var i = 0; i < 3; i++) {
        await tick(); // t+120 .. t+240
      }
      expect(backend.historyRequests, hasLength(5), reason: 'rate-limited');
      await tick(); // t+300: 5 min after the failed anchor started

      expect(songOf(1), 'Song X');
      expect(backend.historyRequests, hasLength(6));
    });

    test('paused (frozen audible instant) never resolves to the live song',
        () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());
      player.pause();

      for (var i = 0; i < 10; i++) {
        await tick();
      }

      expect(songOf(1), 'Song X');
      expect(service().playedCutoffFor(1), t(-138));
    });

    test(
        'pause disconnect (no end call) keeps the paused title; a station '
        'switch clears it', () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());
      player
        ..active = false // 60 s disconnect: no live HLS loaded
        ..latency = null;

      await tick();
      await service().refreshStations();
      expect(songOf(1), 'Song X');
      expect(service().playedCutoffFor(1), t(-138), reason: 'heardAt');

      player.playingId = 2;
      service().onAlignedPlaybackEnded();
      expect(songOf(1), 'Song Y');
    });

    test(
        'Android TV (preferLiveMetadata) never aligns: a boundary refresh '
        'runs a live follow-up', () async {
      backend.songChange(1, t(-300), x);
      await start();
      service().preferLiveMetadata = true;
      player.playHls(1, twoMin);
      final b = t(5);
      backend.songChange(1, b, n, insertedAt: t(17));
      await clock.advance(const Duration(seconds: 10));

      await drive(service().refreshMetadataNow(boundary: b), minute);

      expect(songOf(1), 'Song N');
      expect(backend.historyRequests, isEmpty);
      expect(backend.metadataRequests, hasLength(3),
          reason: 'startup + diff before ingestion + diff after');
    });

    test(
        'an unsettled anchor (instant mode) gets exactly one re-check after '
        'the ingestion window', () async {
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, const Duration(seconds: 6));
      // The row heard at A = t-6 is ingested only after the first answer.
      backend.songChange(1, t(-8), n, insertedAt: t(20));

      await drive(service().refreshMetadataNow(), const Duration(seconds: 30));
      expect(songOf(1), 'Song X');
      expect(backend.historyRequests, hasLength(1));
      await clock.advance(const Duration(seconds: 30)); // A + 60 s

      expect(songOf(1), 'Song N');
      expect(backend.historyRequests, hasLength(2));
      await clock.advance(const Duration(minutes: 4));
      expect(backend.historyRequests, hasLength(2), reason: 'no chain');
    });

    test(
        'the anchor re-check never regresses a resolved change to an older '
        'song from a stale shared edge copy', () async {
      backend.songChange(1, t(-300), x);
      // Y starts at t+10 and is ingested 20 s later.
      backend.songChange(1, t(10), y, insertedAt: t(30));
      await start();
      player.playHls(1, const Duration(seconds: 20)); // instant: A = now-20
      await drive(service().refreshMetadataNow(), const Duration(seconds: 25));
      expect(songOf(1), 'Song X', reason: 'unsettled: one re-check at t+40');

      // Another listener in the same 10 s bucket fetches the key the
      // re-check will use (to = ceil10(t+20)) before Y is ingested; the
      // edge keeps that copy for 60 s.
      final recheckKey = HistoryWindow(epochOf(t(20)) - 3600, epochOf(t(20)));
      await SongHistoryService.fetchPage('rve-suceava', recheckKey,
          client: backend.client);

      await clock.advance(const Duration(seconds: 5)); // t+30
      await drive(service().refreshMetadataNow(boundary: t(10)),
          const Duration(seconds: 1));
      expect(songOf(1), 'Song Y', reason: 'the change resolved Y');

      await clock.advance(const Duration(seconds: 12)); // re-check at t+40
      expect(toOf(backend.historyRequests.last), recheckKey.to,
          reason: 'the re-check got the stale copy');
      expect(songOf(1), 'Song Y', reason: "Y started at t+10 <= A' = t+20");
    });

    test(
        'history request window never exceeds now-2 (instant mode) and a '
        'future error counts as a failed attempt', () async {
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, const Duration(seconds: 6));
      await drive(service().refreshMetadataNow(), const Duration(minutes: 2));
      final before = backend.historyRequests.length;
      // The device clock runs 10 s ahead of the server.
      backend.serverClockOffset = const Duration(seconds: -10);
      backend.songChange(1, clock.now.subtract(const Duration(seconds: 6)), n);

      await drive(service().refreshMetadataNow(
          boundary: clock.now.subtract(const Duration(seconds: 6))));

      final first = backend.historyRequests[before];
      expect(toOf(first), lessThanOrEqualTo(clock.epoch - 2));
      expect(songOf(1), 'Song X', reason: 'the API rejected the window');
      await clock.advance(const Duration(seconds: 3));
      expect(backend.historyRequests.length, before + 2,
          reason: 'the error was retried with a new key');
    });
  });

  group('sync queue', () {
    test('coalesced liveMetadataChanged awaits the drained work', () async {
      await start();
      backend.beforeMetadataResponse =
          (_) => clock.wait(const Duration(seconds: 5));
      await clock.advance(minute);
      unawaited(service().enqueueSync(SyncReason.periodic));
      await clock.settle();

      var done = false;
      unawaited(service()
          .enqueueSync(SyncReason.liveMetadataChanged)
          .then((_) => done = true));
      await clock.advance(const Duration(seconds: 5));
      expect(done, isFalse, reason: 'its diff has only just started');
      expect(backend.metadataRequests, hasLength(3));
      await clock.advance(const Duration(seconds: 5));
      expect(done, isTrue);
    });

    test(
        'pending periodic + stationPlayed run one live diff, without the '
        'catalog, and the periodic side work still runs', () async {
      await start();
      backend.beforeMetadataResponse =
          (_) => clock.wait(const Duration(seconds: 5));
      await clock.advance(minute);
      unawaited(service().enqueueSync(SyncReason.liveMetadataChanged));
      await clock.settle();
      final graphql = backend.graphqlRequests.length;
      final private = backend.privateRequests.length;

      unawaited(service().enqueueSync(SyncReason.periodic));
      unawaited(service().enqueueSync(SyncReason.stationPlayed));
      await clock.advance(const Duration(seconds: 20));

      expect(backend.graphqlRequests, hasLength(graphql));
      expect(backend.metadataRequests, hasLength(3));
      expect(backend.metadataRequests.last.queryParameters,
          contains('changes_from_timestamp'));
      expect(backend.privateRequests, hasLength(private + 1));
    });

    test(
        'a station switch fetches the songs, not the catalog: the songs '
        'never wait for it', () async {
      backend.songChange(2, t(-300), p);
      await start();
      final graphql = backend.graphqlRequests.length;
      backend.songChange(2, t(20), q);
      await clock.advance(const Duration(seconds: 30));

      await drive(service().onStationPlayed());

      expect(songOf(2), 'Song Q');
      expect(backend.graphqlRequests, hasLength(graphql));
      expect(backend.metadataRequests.last.queryParameters,
          containsPair('changes_from_timestamp', '${epochOf(t(-60))}'));
    });

    test('a manual refresh queued with a station switch still gets the catalog',
        () async {
      await start();
      backend.beforeMetadataResponse =
          (_) => clock.wait(const Duration(seconds: 5));
      await clock.advance(minute);
      unawaited(service().enqueueSync(SyncReason.periodic));
      await clock.settle();
      final graphql = backend.graphqlRequests.length;

      unawaited(service().enqueueSync(SyncReason.stationPlayed));
      unawaited(service().enqueueSync(SyncReason.manualRefresh));
      await clock.advance(const Duration(seconds: 20));

      expect(backend.graphqlRequests, hasLength(graphql + 1));
    });

    test('aligned resolution is not dropped while stationPlayed is pending',
        () async {
      backend.songChange(1, t(-300), x);
      backend.songChange(1, t(-60), y);
      await start();
      backend.beforeMetadataResponse =
          (_) => clock.wait(const Duration(seconds: 5));
      await clock.advance(minute);
      unawaited(service().enqueueSync(SyncReason.periodic));
      await clock.settle();
      unawaited(service().onStationPlayed());
      player.playHls(1, const Duration(seconds: 138));

      await drive(service().refreshMetadataNow());

      expect(songOf(1), 'Song X', reason: 'resolved outside the queue');
      await clock.advance(const Duration(seconds: 20));
      expect(songOf(1), 'Song X');
    });
  });

  group('live signals', () {
    test(
        'TV: boundary follow-up retries the live diff until a row >= B-1.5 '
        'appears, max 3 retries', () async {
      backend.songChange(1, t(-300), x);
      await start();
      service().preferLiveMetadata = true;
      player.playHls(1, twoMin);
      await clock.advance(const Duration(seconds: 10));

      // The row never shows up.
      await drive(service().refreshMetadataNow(boundary: t(5)),
          const Duration(minutes: 2));

      expect(backend.metadataRequests, hasLength(1 + 4));
      expect(songOf(1), 'Song X');
    });

    test(
        'ICY: follow-up retries until the station\'s live row starts within '
        'the last 30 s', () async {
      backend.songChange(1, t(-300), x);
      await start();
      player.playingId = 1; // direct stream: no time-shifted HLS
      await clock.advance(const Duration(seconds: 30));
      backend.songChange(1, t(28), n, insertedAt: t(38));

      await drive(service().refreshMetadataNow(), minute);

      expect(songOf(1), 'Song N');
      expect(backend.metadataRequests, hasLength(1 + 2));
    });
  });

  group('backend B3 (R10) and listener-only rows', () {
    test(
        'Mode-2 now_playing.timestamp stays the song start after listener '
        'reports, so the live shortcut still applies', () async {
      final b = t(-100);
      backend.songChange(1, t(-400), x);
      backend.songChange(1, b, n);
      for (final s in [40, 50, 60]) {
        backend.listenerReport(1, b.add(Duration(seconds: s)),
            song: n, songStartedAt: b);
      }
      await start();
      expect(stationOf(1).rawStationData.now_playing?.timestamp,
          b.toIso8601String());
      player.playHls(1, const Duration(seconds: 90));

      await drive(service().refreshMetadataNow(boundary: b));

      expect(songOf(1), 'Song N');
      expect(backend.historyRequests, isEmpty);
    });

    test(
        'an old-song listener row inside the change window is skipped '
        '(seeded dedupe)', () async {
      backend.seedHistoryDedupe = true;
      final b = t(10);
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      // Old song's audience at B+3, then the change report (started at B)
      // stamped just behind it.
      backend.listenerReport(1, b.add(const Duration(seconds: 3)),
          song: x, songStartedAt: t(-300));
      backend.songChange(1, b.add(const Duration(milliseconds: 3001)), n,
          songStartedAt: b);
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(boundary: b));

      expect(songOf(1), 'Song N');
    });

    test(
        'R9: rows (old song, B+1) and (new song, B+1.001) in the window '
        'apply the new song', () async {
      backend.exposeSongStart = false; // B3 as first designed
      final b = t(10);
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      expect(songOf(1), 'Song X');
      backend.listenerReport(1, b.add(const Duration(seconds: 1)),
          song: x, songStartedAt: t(-300));
      backend.songChange(1, b.add(const Duration(milliseconds: 1001)), n);
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(boundary: b));

      expect(songOf(1), 'Song N');
      final page = backend.historyRequests.last;
      expect(fromOf(page), epochOf(b) - 2);
    });

    test(
        'the same song on both sides of a boundary is not a change: retried '
        'until settled, the title stays', () async {
      backend.exposeSongStart = false;
      final b = t(10);
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      backend.listenerReport(1, b.add(const Duration(seconds: 1)),
          song: x, songStartedAt: t(-300));
      await clock.advance(const Duration(seconds: 130));

      await drive(service().refreshMetadataNow(boundary: b), minute);

      expect(songOf(1), 'Song X');
      expect(backend.historyRequests, hasLength(1),
          reason: 'one settled change lookup (the anchor was live-proven)');
    });
  });

  group('sanitizer through the pipeline (C12)', () {
    test(
        'stale (>14 d) song is hidden in the published station, while the '
        'resolver still reads the raw row timing', () async {
      backend.songChange(1, t0.subtract(const Duration(days: 20)), x);
      backend.songChange(3, t0.subtract(const Duration(days: 20)), p);
      backend.songChange(4, t(-60), q);
      await start();

      expect(songOf(3), '');
      expect(stationOf(3).songId, -1);
      expect(songOf(4), 'Song Q');

      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      expect(backend.historyRequests, isEmpty,
          reason: 'the raw live row proved the audible song');
      expect(songOf(1), '');
    });

    test(
        'a frozen song with fresh listener reports still ages from its '
        'start (B3/R10)', () async {
      final start0 = t0.subtract(const Duration(days: 20));
      backend.songChange(3, start0, p);
      backend.listenerReport(3, t(-60), song: p, songStartedAt: start0);
      await start();

      expect(songOf(3), '');
    });

    test('a song title that only repeats the station name is hidden', () async {
      backend.songChange(1, t(-60), const FakeSong(40, 'RVE  Suceava'));
      await start();

      expect(songOf(1), '');
    });
  });

  group('playedCutoffFor (C10)', () {
    test(
        'returns the audible instant for the overlay station, its heardAt '
        'while A is null, and now for every other station', () async {
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, const Duration(seconds: 138));
      await drive(service().refreshMetadataNow());

      expect(service().playedCutoffFor(1), t(-138));
      expect(service().playedCutoffFor(2), t0);
      await clock.advance(const Duration(seconds: 10));
      expect(service().playedCutoffFor(1), t(-128));

      player.latency = null; // reloading: no audible instant yet
      expect(service().playedCutoffFor(1), t(-138));

      service().preferLiveMetadata = true;
      service().onAlignedPlaybackEnded();
      expect(service().playedCutoffFor(1), t(10));
    });
  });

  group('listening timeline', () {
    // iOS seeking 2 minutes behind live on index.m3u8: 120 s plus AVPlayer's
    // 18 s hold-back. The listening timestamp at t0 is
    // floor10(t0 - 138 s) = t-140.
    const delay = Duration(seconds: 138);
    var listeningDelay = Duration.zero;

    /// [start] with the listening delay wired before the startup sync, as
    /// main.dart does.
    Future<StationDataService> startListening(Duration value) async {
      listeningDelay = value;
      final s = backend.newService(prefs);
      player.attach(s);
      s.getListeningDelay = () => listeningDelay;
      current = s;
      await s.enqueueSync(SyncReason.startup);
      return s;
    }

    List<Uri> metadataAt(DateTime instant) => backend.metadataRequests
        .where((u) => u.queryParameters['timestamp'] == '${epochOf(instant)}')
        .toList();

    setUp(() {
      backend
        ..addStation(20, 'hls-a', 'HLS A', hls: true)
        ..addStation(21, 'hls-b', 'HLS B', hls: true);
    });

    test(
        'an HLS station shows its song at now - delay with live listeners; '
        'a direct stream stays live', () async {
      backend.songChange(20, t(-300), x, listeners: 10);
      backend.songChange(20, t(-60), y, listeners: 42);
      backend.songChange(2, t(-300), p);
      backend.songChange(2, t(-60), q);

      await startListening(delay);

      expect(songOf(20), 'Song X', reason: 'what tapping it plays');
      expect(stationOf(20).totalListeners, 42);
      expect(songOf(2), 'Song Q', reason: 'a direct stream plays live');
      final listening = metadataAt(t(-140)).single;
      expect(listening.queryParameters['changes_from_timestamp'], isNull);
    });

    test(
        'leaving a station keeps its song: the audible overlay hands over to '
        'the listening row instead of jumping to the live one', () async {
      backend.songChange(20, t(-300), x);
      backend.songChange(20, t(-60), y);
      await startListening(delay);
      player.playHls(20, delay);
      await drive(service().refreshMetadataNow());
      expect(songOf(20), 'Song X');

      player
        ..playingId = 21
        ..active = false;
      service().onAlignedPlaybackEnded();

      expect(songOf(20), 'Song X');
    });

    test('a tapped station shows the song it plays before the anchor',
        () async {
      backend.songChange(21, t(-300), p);
      backend.songChange(21, t(-60), q);
      await startListening(delay);
      expect(songOf(21), 'Song P');

      player
        ..playHls(21, delay)
        ..latency = null; // still anchoring
      await drive(service().onStationPlayed());

      expect(songOf(21), 'Song P', reason: 'never the live song first');
    });

    test(
        'the live song shows once it started at now - delay, though the '
        'listening timestamp, floored to 10 s, is before it', () async {
      backend.songChange(20, t(-300), x);
      backend.songChange(20, t(-139), y);

      await startListening(delay);

      expect(metadataAt(t(-140)), hasLength(1));
      expect(songOf(20), 'Song Y', reason: 'what tapping it plays');
    });

    test(
        'a station picked between two syncs shows the live song that reached '
        'the listeners since the last one', () async {
      backend.songChange(20, t(-300), x);
      backend.songChange(20, t(-100), y);
      await startListening(delay);
      expect(songOf(20), 'Song X');

      // No sync: now - delay moves from t-138 to t-88, past Song Y's start.
      await clock.advance(const Duration(seconds: 50));
      expect(songOf(20), 'Song X', reason: 'as of the last publish');

      expect(service().shownNow(stationOf(20)).songTitle, 'Song Y');
      expect(songOf(20), 'Song Y', reason: 'the list is republished');
    });

    test(
        'a live list fetched less than the ingestion window after now - '
        'delay keeps the listening row: a later song may not be in it yet',
        () async {
      backend.songChange(20, t(-300), x);
      backend.songChange(20, t(-40), y);
      await startListening(delay);

      // now - delay = t-28: Song Y started before it, but the live list
      // (t0) is only 28 s after it.
      await clock.advance(const Duration(seconds: 110));

      expect(service().shownNow(stationOf(20)).songTitle, 'Song X');
    });

    group('lookahead at 5 minutes', () {
      // The 5-minute variant start plus one segment. floor10(t0 - 306 s) =
      // t-310, and the lookahead reads 70 s later: t-240.
      const fiveMin = Duration(seconds: 306);

      test(
          'a station picked a minute after the last sync shows the song that '
          'started since, which is not the live song', () async {
        backend.songChange(20, t(-600), x);
        backend.songChange(20, t(-280), y);
        backend.songChange(20, t(-100), z);
        await startListening(fiveMin);
        expect(metadataAt(t(-240)), hasLength(1));
        expect(songOf(20), 'Song X', reason: 'Song Y starts after t-306');

        // No sync: now - delay moves from t-306 to t-256, past Song Y's start.
        await clock.advance(const Duration(seconds: 50));

        expect(service().shownNow(stationOf(20)).songTitle, 'Song Y');
      });

      test('periodic ticks diff the lookahead from its own cursor', () async {
        await startListening(fiveMin);
        expect(metadataAt(t(-240)).single.queryParameters,
            isNot(contains('changes_from_timestamp')));

        await tick();

        // t+60: the listening timestamp is t-250, the lookahead t-180.
        final diff = metadataAt(t(-180)).single;
        expect(diff.queryParameters['changes_from_timestamp'],
            '${epochOf(t(-300))}');
      });

      test(
          'at 2 minutes the lookahead instant is not final yet: no lookahead '
          'request', () async {
        await startListening(const Duration(seconds: 126));

        // floor10(t0 - 126 s) = t-130; a lookahead would read t-60.
        expect(metadataAt(t(-130)), hasLength(1));
        expect(metadataAt(t(-60)), isEmpty);
      });
    });

    test('periodic ticks diff the listening timeline from its own cursor',
        () async {
      backend.songChange(20, t(-300), x);
      await startListening(delay);
      backend.songChange(20, t(-100), y);
      backend.songChange(20, t(30), z);

      await tick();

      final diff = metadataAt(t(-80)).single;
      expect(
          diff.queryParameters['changes_from_timestamp'], '${epochOf(t(-200))}');
      expect(songOf(20), 'Song Y', reason: 'Song Z is still ahead');
    });

    test(
        'a longer delay refetches the whole list at the earlier instant; a '
        'zero delay shows the live list again', () async {
      backend.songChange(20, t(-400), x);
      backend.songChange(20, t(-200), y);
      backend.songChange(20, t(-60), z);
      await startListening(delay);
      expect(songOf(20), 'Song Y');

      listeningDelay = const Duration(seconds: 318); // 5 min + hold-back
      service().onListeningDelayChanged();
      await clock.settle();

      expect(songOf(20), 'Song X');
      expect(metadataAt(t(-320)).single.queryParameters,
          isNot(contains('changes_from_timestamp')));

      listeningDelay = Duration.zero;
      service().onListeningDelayChanged();
      await clock.settle();

      expect(songOf(20), 'Song Z');
    });

    test('the playing station on a live stream (HLS failover) shows live',
        () async {
      backend.songChange(20, t(-300), x);
      backend.songChange(20, t(-60), y);
      await startListening(delay);

      player
        ..playingId = 20
        ..liveStream = true;
      await drive(service().onStationPlayed());

      expect(songOf(20), 'Song Y');
    });

    test('playedCutoffFor follows the listening timeline', () async {
      backend.songChange(20, t(-300), x);
      backend.songChange(2, t(-300), p);
      await startListening(delay);

      expect(service().playedCutoffFor(20), t(-138));
      expect(service().playedCutoffFor(2), t0, reason: 'direct stream');
    });

    test('a live stream song change does not refetch the listening timeline',
        () async {
      await startListening(delay);
      final before = backend.metadataRequests.length;

      await drive(service().enqueueSync(SyncReason.liveMetadataChanged));

      expect(backend.metadataRequests, hasLength(before + 1));
      expect(metadataAt(t(-140)), hasLength(1));
    });

    test('no delay or the TV live mode makes no listening request', () async {
      await startListening(Duration.zero);
      expect(backend.metadataRequests, hasLength(1));

      final tv = backend.newService(prefs)
        ..getListeningDelay = (() => delay)
        ..preferLiveMetadata = true;
      await tv.enqueueSync(SyncReason.startup);
      tv.dispose();
      expect(backend.metadataRequests, hasLength(2));
    });

    test(
        'station switches within the same 10 s send each timeline\'s diff '
        'once', () async {
      await startListening(delay);
      for (var i = 0; i < 3; i++) {
        await service().onStationPlayed();
      }

      expect(metadataAt(t0), hasLength(2), reason: 'live: startup + diff');
      expect(metadataAt(t(-140)), hasLength(2),
          reason: 'listening: startup + diff');
      expect(metadataAt(t(-70)), hasLength(2),
          reason: 'lookahead: startup + diff');
    });
  });

  group('B14 two-sighting flow', () {
    test(
        'EPOCH first without X-*, then with them: the boundary reaches the '
        'service with the hint and applies it with zero requests', () async {
      backend.songChange(1, t(-300), x);
      await start();
      player.playHls(1, twoMin);
      await drive(service().refreshMetadataNow());
      final epoch = epochOf(t(10));
      final startedAt =
          DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true)
              .toIso8601String();
      String playlist(String attributes) => playlistText(
            firstPdt: t(-20),
            header: [
              '#EXT-X-RC-METADATA-CHANGED:STARTED-AT="$startedAt",'
                  'EPOCH=$epoch$attributes',
            ],
          );
      final queue = SongBoundaryQueue();

      final first = HlsPlaylistSnapshot.parse(playlist(''), fetchedAt: t(12))!;
      queue.add(first.songBoundaries);
      final second = HlsPlaylistSnapshot.parse(
          playlist(',X-SONG-ID="143962",X-TITLE="- Ai creat orice faptura",'
              'X-ARTIST="Hristic",X-ARTIST-ID="191"'),
          fetchedAt: t(22))!;
      queue.add(second.songBoundaries);
      await clock.advance(const Duration(seconds: 130));
      final due = queue.takeReached(player.audible!)!;

      await drive(
          service().refreshMetadataNow(boundary: due.at, hint: due.hint));

      expect(songOf(1), '- Ai creat orice faptura');
      expect(stationOf(1).songArtist, 'Hristic');
      expect(stationOf(1).songId, 143962);
      expect(backend.historyRequests, isEmpty);
    });
  });

  group('catalog persistence', () {
    const cacheKey = 'cached_stations_data';

    test('the station list is not normalized into the GraphQL cache',
        () async {
      await start();

      expect(service().stations.value, hasLength(10));
      expect(backend.graphqlClient.cache.store.toMap(), isEmpty);
    });

    test('an unchanged catalog is rewritten at most every 30 minutes',
        () async {
      await start();
      expect(prefs.getString(cacheKey), isNotNull,
          reason: 'the first write of the session always happens');
      await prefs.remove(cacheKey);

      await clock.advance(const Duration(minutes: 10));
      await service().enqueueSync(SyncReason.manualRefresh);
      expect(prefs.getString(cacheKey), isNull);

      await clock.advance(const Duration(minutes: 21));
      await service().enqueueSync(SyncReason.manualRefresh);
      expect(prefs.getString(cacheKey), isNotNull);
    });

    test('a structural change is persisted immediately', () async {
      await start();
      await prefs.remove(cacheKey);
      backend.addStation(11, 's11', 'Station 11');

      await service().enqueueSync(SyncReason.manualRefresh);

      expect(prefs.getString(cacheKey), contains('s11'));
    });
  });

  group('lifecycle', () {
    test(
        'suspend (task removed, process alive) stops the background work '
        'but keeps the service usable; only dispose closes the client it '
        'owns', () async {
      backend.songChange(1, t(-300), x);
      final owned = _ClosableClient(backend.client);
      final s = http.runWithClient(
        () => StationDataService(
          graphqlClient: backend.graphqlClient,
          privateStationsService: PrivateStationsService(
            httpClient: backend.client,
            prefs: prefs,
            deviceIdProvider: () => 'device-1',
          ),
          clock: clock.call,
          wait: clock.wait,
        ),
        () => owned,
      );
      current = s;
      player.attach(s);
      await s.enqueueSync(SyncReason.startup);
      s.resumePeriodic();

      s.suspend();
      expect(owned.closed, isFalse);

      // The relaunch reuses this instance (audio_service's cached engine).
      backend.songChange(1, t(30), y);
      await clock.advance(minute);
      await s.onAppResumed();
      expect(songOf(1), 'Song Y');

      s.dispose();
      expect(owned.closed, isTrue);
    });
  });

}

/// A client that, like the platform client, refuses requests once closed.
class _ClosableClient extends http.BaseClient {
  _ClosableClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) {
      throw http.ClientException('Client is already closed.', request.url);
    }
    return _inner.send(request);
  }

  @override
  void close() => closed = true;
}
