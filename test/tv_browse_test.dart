/// Widget tests for the Android TV TvBrowse rails page:
/// header, empty state, Now Playing hero, conditional rails.
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
import 'package:radio_crestin/tv/pages/tv_browse.dart';
import 'package:radio_crestin/tv/widgets/tv_station_row.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  @override
  final BehaviorSubject<Station?> currentStation =
      BehaviorSubject.seeded(null);

  void setCurrent(Station? s) => currentStation.add(s);

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
  await GetIt.I.reset();
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  GetIt.I.registerSingleton<SharedPreferences>(prefs);
  final audio = _FakeAudioHandler();
  final data = _FakeStationDataService();
  GetIt.I.registerSingleton<AppAudioHandler>(audio);
  GetIt.I.registerSingleton<StationDataService>(data);
  GetIt.I.registerSingleton<PlayCountService>(PlayCountService());
  return _Fakes(audio, data);
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => await GetIt.I.reset());

  group('TvBrowse — header', () {
    testWidgets('always shows the brand mark and title', (tester) async {
      await _registerFakes();
      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      expect(find.text('Radio Crestin'), findsOneWidget);
      expect(find.byIcon(Icons.radio_rounded), findsOneWidget);
    });
  });

  group('TvBrowse — empty state', () {
    testWidgets('shows "Nu sunt posturi" when station list is empty', (tester) async {
      await _registerFakes();
      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      expect(find.text('Nu sunt posturi'), findsOneWidget);
      expect(find.byType(TvStationRow), findsNothing);
    });
  });

  group('TvBrowse — populated rails', () {
    testWidgets('renders all four rails when no station is currently playing',
        (tester) async {
      final fakes = await _registerFakes();
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
      ]);
      fakes.data.favoriteStationSlugs.add(['a']);

      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      // 'Cele mai ascultate' is hidden when nothing has been played.
      // skipOffstage:false because rails far enough down can be off-screen
      // in the default 800x600 test viewport — they're still in the tree.
      expect(find.text('Favoritele tale', skipOffstage: false), findsOneWidget);
      expect(find.text('Pentru tine', skipOffstage: false), findsOneWidget);
      expect(find.text('Toate stațiile', skipOffstage: false), findsOneWidget);
      expect(find.text('Cele mai ascultate', skipOffstage: false), findsNothing);
    });

    testWidgets('skips the favorites rail when no station is favorited',
        (tester) async {
      final fakes = await _registerFakes();
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      ]);
      fakes.data.favoriteStationSlugs.add(<String>[]);

      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      expect(find.text('Favoritele tale'), findsNothing);
      expect(find.text('Pentru tine'), findsOneWidget);
    });
  });

  group('TvBrowse — Now Playing hero', () {
    // The hero card and the rail cards both show the station title, so
    // counting Text matches is the cheapest way to detect the hero
    // without exposing the private _NowPlayingHero widget type.
    testWidgets('hero adds one title occurrence on top of the rails',
        (tester) async {
      final fakes = await _registerFakes();
      final stationA = StationFactory.createStation(
        id: 1, slug: 'a', title: 'Alpha Radio',
      );
      fakes.data.stations.add([stationA]);

      // First render with no hero — count baseline rail occurrences.
      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();
      final railCount = find.text('Alpha Radio').evaluate().length;

      // Now flip on the current station and rebuild — hero should appear.
      fakes.audio.setCurrent(stationA);
      await tester.pump();
      final withHeroCount = find.text('Alpha Radio').evaluate().length;

      expect(withHeroCount, railCount + 1);
    });
  });
}
