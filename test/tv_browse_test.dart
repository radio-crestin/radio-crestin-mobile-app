/// Widget tests for the Android TV TvBrowse page: header, empty state,
/// "Pentru tine" grid.
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
    testWidgets('shows "Nu sunt posturi" when station list is empty',
        (tester) async {
      await _registerFakes();
      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      expect(find.text('Nu sunt posturi'), findsOneWidget);
      expect(find.text('Pentru tine'), findsNothing);
    });
  });

  group('TvBrowse — populated grid', () {
    testWidgets('renders the "Pentru tine" header and station titles',
        (tester) async {
      final fakes = await _registerFakes();
      fakes.data.stations.add([
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
        StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
      ]);

      await tester.pumpWidget(_wrap(TvBrowse(
        onBack: () {},
        onStationSelected: (_) {},
      )));
      await tester.pump();

      expect(find.text('Pentru tine'), findsOneWidget);
      // Each station's title appears in the grid card.
      expect(find.text('A', skipOffstage: false), findsOneWidget);
      expect(find.text('B', skipOffstage: false), findsOneWidget);
      expect(find.text('C', skipOffstage: false), findsOneWidget);
    });
  });
}
