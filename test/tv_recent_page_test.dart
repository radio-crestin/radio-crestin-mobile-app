/// Widget tests for the Android TV TvRecentPage:
/// empty state, ordering from prefs, currently playing mark, favorite mark,
/// onSelect/onFavoriteToggle wiring, and the "add to recents on station
/// change" subscription.
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/tv/pages/tv_recent_page.dart';
import 'package:radio_crestin/tv/widgets/tv_station_card.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  @override
  final BehaviorSubject<Station?> currentStation =
      BehaviorSubject.seeded(null);

  Station? lastPlayed;
  final List<String> customActions = [];

  void setCurrent(Station? s) => currentStation.add(s);

  @override
  Future<void> playStation(Station station, {bool? fromFavorites}) async {
    lastPlayed = station;
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    customActions.add(name);
    return null;
  }

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FakeStationDataService implements StationDataService {
  final BehaviorSubject<List<Station>> _stations =
      BehaviorSubject.seeded(<Station>[]);
  final BehaviorSubject<List<String>> _favs =
      BehaviorSubject.seeded(<String>[]);

  @override
  BehaviorSubject<List<Station>> get stations => _stations;

  @override
  BehaviorSubject<List<String>> get favoriteStationSlugs => _favs;

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _Fakes {
  final _FakeAudioHandler audio;
  final _FakeStationDataService data;
  _Fakes(this.audio, this.data);
}

Future<_Fakes> _registerFakes({Map<String, Object> initialPrefs = const {}}) async {
  // GetIt.reset() is async — must await or registrations land before the
  // reset finishes and get wiped.
  await GetIt.I.reset();
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  GetIt.I.registerSingleton<SharedPreferences>(prefs);
  final audio = _FakeAudioHandler();
  final data = _FakeStationDataService();
  GetIt.I.registerSingleton<AppAudioHandler>(audio);
  GetIt.I.registerSingleton<StationDataService>(data);
  GetIt.I.registerSingleton<PlayCountService>(PlayCountService());
  return _Fakes(audio, data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => await GetIt.I.reset());

  group('TvRecentPage — empty state', () {
    testWidgets('shows the "no recents" hero copy when prefs are empty', (tester) async {
      await _registerFakes();
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Niciun post redat recent'), findsOneWidget);
      expect(find.text('Posturile redate vor apărea aici'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsOneWidget);
    });

    testWidgets('shows the empty hero when recents reference unknown slugs', (tester) async {
      // Recents list mentions 'gone' but no station with that slug exists in
      // the stations stream — the page should treat it as empty.
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['gone'],
      });
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      ]);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Niciun post redat recent'), findsOneWidget);
    });
  });

  group('TvRecentPage — populated grid', () {
    testWidgets('renders the grid header with localized title and count', (tester) async {
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['a', 'b'],
      });
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
      ]);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Redate Recent'), findsOneWidget);
      expect(find.text('2 posturi'), findsOneWidget);
    });

    testWidgets('renders cards in the order stored in prefs', (tester) async {
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['c', 'a', 'b'],
      });
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
      ]);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      final cards = tester
          .widgetList<TvStationCard>(find.byType(TvStationCard))
          .toList();
      expect(cards.map((c) => c.station.slug).toList(), ['c', 'a', 'b']);
    });

    testWidgets('drops slugs that no longer exist in the stations list', (tester) async {
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['a', 'gone', 'c'],
      });
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
      ]);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      final cards = tester
          .widgetList<TvStationCard>(find.byType(TvStationCard))
          .toList();
      expect(cards.map((c) => c.station.slug).toList(), ['a', 'c']);
      expect(find.text('2 posturi'), findsOneWidget);
    });

    testWidgets('marks the currently playing station and favorite stations correctly',
        (tester) async {
      final stationA = StationFactory.createStation(id: 1, slug: 'a', title: 'A');
      final stationB = StationFactory.createStation(id: 2, slug: 'b', title: 'B');

      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['a', 'b'],
      });
      fakes.data.stations.add([stationA, stationB]);
      fakes.data.favoriteStationSlugs.add(['a']);
      fakes.audio.setCurrent(stationB);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      final cards = tester
          .widgetList<TvStationCard>(find.byType(TvStationCard))
          .toList();
      expect(cards.firstWhere((c) => c.station.slug == 'a').isFavorite, isTrue);
      expect(cards.firstWhere((c) => c.station.slug == 'b').isFavorite, isFalse);
      expect(cards.firstWhere((c) => c.station.slug == 'a').isPlaying, isFalse);
      expect(cards.firstWhere((c) => c.station.slug == 'b').isPlaying, isTrue);
    });
  });

  group('TvRecentPage — interactions', () {
    testWidgets('selecting a card calls playStation and onOpenNowPlaying', (tester) async {
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['a'],
      });
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      ]);

      bool opened = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvRecentPage(onOpenNowPlaying: () => opened = true),
        ),
      ));
      await tester.pumpAndSettle();

      final card = tester.widget<TvStationCard>(find.byType(TvStationCard));
      card.onSelect();

      expect(fakes.audio.lastPlayed?.slug, 'a');
      expect(opened, isTrue);
    });

    testWidgets('favoriting a card invokes audioHandler.customAction("toggleFavorite")',
        (tester) async {
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['a'],
      });
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      ]);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      final card = tester.widget<TvStationCard>(find.byType(TvStationCard));
      card.onFavoriteToggle();

      expect(fakes.audio.customActions, contains('toggleFavorite'));
    });
  });

  group('TvRecentPage — auto-add on station change', () {
    testWidgets('emitting a new currentStation prepends its slug to recents in prefs',
        (tester) async {
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': <String>['a'],
      });
      final stationA = StationFactory.createStation(id: 1, slug: 'a', title: 'A');
      final stationB = StationFactory.createStation(id: 2, slug: 'b', title: 'B');
      fakes.data.stations.add([stationA, stationB]);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      // Simulate playback switching to station B.
      fakes.audio.setCurrent(stationB);
      await tester.pumpAndSettle();

      final prefs = GetIt.I<SharedPreferences>();
      expect(prefs.getStringList('tv_recent_stations'), ['b', 'a']);
    });

    testWidgets('caps the recent list at 30 entries', (tester) async {
      final initial = List.generate(30, (i) => 's$i');
      final fakes = await _registerFakes(initialPrefs: {
        'tv_recent_stations': initial,
      });
      final stations = List.generate(
        31,
        (i) => StationFactory.createStation(id: i + 1, slug: 's$i', title: 'S$i'),
      );
      fakes.data.stations.add(stations);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvRecentPage()),
      ));
      await tester.pumpAndSettle();

      // Push a 31st station into recents — the oldest one (s29) drops off.
      fakes.audio.setCurrent(stations.last);
      await tester.pumpAndSettle();

      final prefs = GetIt.I<SharedPreferences>();
      final stored = prefs.getStringList('tv_recent_stations')!;
      expect(stored.length, 30);
      expect(stored.first, 's30');
      expect(stored, isNot(contains('s29')));
    });
  });
}
