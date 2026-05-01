/// Widget tests for the Android TV TvFavoritesPage:
/// empty state, populated grid, current-station indicator, and tap behavior.
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/tv/pages/tv_favorites_page.dart';
import 'package:radio_crestin/tv/widgets/tv_station_card.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  @override
  final BehaviorSubject<Station?> currentStation =
      BehaviorSubject.seeded(null);

  // Spy state — tests assert against these.
  Station? lastPlayed;
  bool? lastPlayedFromFavorites;
  final List<String> customActions = [];

  void setCurrent(Station? s) => currentStation.add(s);

  @override
  Future<void> playStation(Station station, {bool? fromFavorites}) async {
    lastPlayed = station;
    lastPlayedFromFavorites = fromFavorites;
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

Future<_Fakes> _registerFakes() async {
  final getIt = GetIt.I;
  getIt.reset();
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  getIt.registerSingleton<SharedPreferences>(prefs);
  final audio = _FakeAudioHandler();
  final data = _FakeStationDataService();
  getIt.registerSingleton<AppAudioHandler>(audio);
  getIt.registerSingleton<StationDataService>(data);
  getIt.registerSingleton<PlayCountService>(PlayCountService());
  return _Fakes(audio, data);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Fakes fakes;

  setUp(() async {
    fakes = await _registerFakes();
  });

  tearDown(() => GetIt.I.reset());

  group('TvFavoritesPage — empty state', () {
    testWidgets('shows the "no favorites" hero copy when nothing is favorited',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvFavoritesPage()),
      ));
      await tester.pump();

      expect(find.text('Nu ai posturi favorite'), findsOneWidget);
      expect(
        find.text('Adaugă posturi la favorite din pagina principală'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    });

    testWidgets('shows the empty hero even when there are stations but no favs',
        (tester) async {
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
      ]);
      fakes.data.favoriteStationSlugs.add(<String>[]);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvFavoritesPage()),
      ));
      await tester.pump();

      expect(find.text('Nu ai posturi favorite'), findsOneWidget);
    });
  });

  group('TvFavoritesPage — populated grid', () {
    testWidgets('renders the grid header with title and count', (tester) async {
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'Gamma'),
      ]);
      fakes.data.favoriteStationSlugs.add(<String>['a', 'c']);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvFavoritesPage()),
      ));
      await tester.pump();

      expect(find.text('Posturi Favorite'), findsOneWidget);
      expect(find.text('2 posturi'), findsOneWidget);
    });

    testWidgets('renders one TvStationCard per favorite (filters non-favorites)',
        (tester) async {
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'Alpha'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'Beta'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'Gamma'),
      ]);
      fakes.data.favoriteStationSlugs.add(<String>['a', 'c']);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvFavoritesPage(), backgroundColor: Colors.black),
      ));
      await tester.pump();

      final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard));
      final stationSlugs = cards.map((c) => c.station.slug).toSet();

      expect(stationSlugs, {'a', 'c'});
      // All cards shown on the favorites page should report isFavorite=true.
      expect(cards.every((c) => c.isFavorite == true), isTrue);
    });

    testWidgets('marks the currently playing favorite as isPlaying=true',
        (tester) async {
      final stationA = StationFactory.createStation(id: 1, slug: 'a', title: 'A');
      final stationB = StationFactory.createStation(id: 2, slug: 'b', title: 'B');

      fakes.data.stations.add([stationA, stationB]);
      fakes.data.favoriteStationSlugs.add(<String>['a', 'b']);
      fakes.audio.setCurrent(stationA);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvFavoritesPage()),
      ));
      await tester.pump();

      final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard));
      final playing = cards.where((c) => c.isPlaying).toList();
      expect(playing.length, 1);
      expect(playing.single.station.slug, 'a');
    });
  });

  group('TvFavoritesPage — interactions', () {
    testWidgets('selecting a card calls playStation(fromFavorites: true) and onOpenNowPlaying',
        (tester) async {
      bool opened = false;
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      ]);
      fakes.data.favoriteStationSlugs.add(<String>['a']);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TvFavoritesPage(onOpenNowPlaying: () => opened = true),
        ),
      ));
      await tester.pump();

      // Trigger the card's onSelect via direct invocation. (The card uses
      // a focusable widget under-the-hood — invoking the callback directly
      // verifies the wiring without depending on TV remote focus traversal.)
      final card = tester.widget<TvStationCard>(find.byType(TvStationCard));
      card.onSelect();

      expect(fakes.audio.lastPlayed?.slug, 'a');
      expect(fakes.audio.lastPlayedFromFavorites, isTrue);
      expect(opened, isTrue);
    });

    testWidgets('toggling favorite on a card calls audioHandler.customAction("toggleFavorite")',
        (tester) async {
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      ]);
      fakes.data.favoriteStationSlugs.add(<String>['a']);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TvFavoritesPage()),
      ));
      await tester.pump();

      final card = tester.widget<TvStationCard>(find.byType(TvStationCard));
      card.onFavoriteToggle();

      expect(fakes.audio.customActions, contains('toggleFavorite'));
    });
  });
}
