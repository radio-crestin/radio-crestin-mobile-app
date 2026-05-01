import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/tv/widgets/tv_station_card.dart';
import 'package:radio_crestin/tv/widgets/tv_station_row.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await GetIt.I.reset();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    GetIt.I.registerSingleton<SharedPreferences>(prefs);
  });

  tearDown(() async => await GetIt.I.reset());

  testWidgets('renders nothing when stations list is empty', (tester) async {
    await tester.pumpWidget(_wrap(const TvStationRow(
      title: 'Empty',
      stations: <Station>[],
      currentStation: null,
      favoriteSlugs: <String>[],
    )));
    await tester.pump();

    // Title is omitted entirely when there are no stations.
    expect(find.text('Empty'), findsNothing);
    expect(find.byType(TvStationCard), findsNothing);
  });

  testWidgets('shows the title and one card per station', (tester) async {
    final stations = [
      StationFactory.createStation(id: 1, slug: 'a', title: 'Alpha'),
      StationFactory.createStation(id: 2, slug: 'b', title: 'Beta'),
      StationFactory.createStation(id: 3, slug: 'c', title: 'Gamma'),
    ];

    await tester.pumpWidget(_wrap(TvStationRow(
      title: 'Pentru tine',
      stations: stations,
      currentStation: null,
      favoriteSlugs: const <String>[],
    )));
    await tester.pump();

    expect(find.text('Pentru tine'), findsOneWidget);
    final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard)).toList();
    expect(cards.map((c) => c.station.slug).toList(), ['a', 'b', 'c']);
  });

  testWidgets('marks the matching currentStation card as isPlaying', (tester) async {
    final a = StationFactory.createStation(id: 1, slug: 'a', title: 'A');
    final b = StationFactory.createStation(id: 2, slug: 'b', title: 'B');

    await tester.pumpWidget(_wrap(TvStationRow(
      title: 'Row',
      stations: [a, b],
      currentStation: b,
      favoriteSlugs: const <String>[],
    )));
    await tester.pump();

    final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard)).toList();
    expect(cards.firstWhere((c) => c.station.slug == 'a').isPlaying, isFalse);
    expect(cards.firstWhere((c) => c.station.slug == 'b').isPlaying, isTrue);
  });

  testWidgets('marks isFavorite based on favoriteSlugs', (tester) async {
    final stations = [
      StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
    ];
    await tester.pumpWidget(_wrap(TvStationRow(
      title: 'Row',
      stations: stations,
      currentStation: null,
      favoriteSlugs: const ['a'],
    )));
    await tester.pump();

    final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard)).toList();
    expect(cards.firstWhere((c) => c.station.slug == 'a').isFavorite, isTrue);
    expect(cards.firstWhere((c) => c.station.slug == 'b').isFavorite, isFalse);
  });

  testWidgets('only the first card receives autofocus when autofocusFirst=true',
      (tester) async {
    final stations = [
      StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
      StationFactory.createStation(id: 3, slug: 'c', title: 'C'),
    ];

    await tester.pumpWidget(_wrap(TvStationRow(
      title: 'Row',
      stations: stations,
      currentStation: null,
      favoriteSlugs: const <String>[],
      autofocusFirst: true,
    )));
    await tester.pump();

    final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard)).toList();
    expect(cards[0].autofocus, isTrue);
    expect(cards[1].autofocus, isFalse);
    expect(cards[2].autofocus, isFalse);
  });

  testWidgets('no card autofocuses when autofocusFirst=false', (tester) async {
    final stations = [
      StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
    ];

    await tester.pumpWidget(_wrap(TvStationRow(
      title: 'Row',
      stations: stations,
      currentStation: null,
      favoriteSlugs: const <String>[],
    )));
    await tester.pump();

    final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard)).toList();
    expect(cards.every((c) => !c.autofocus), isTrue);
  });

  testWidgets('onSelect on a card forwards to onStationSelected', (tester) async {
    Station? selected;
    final stations = [
      StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
      StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
    ];

    await tester.pumpWidget(_wrap(TvStationRow(
      title: 'Row',
      stations: stations,
      currentStation: null,
      favoriteSlugs: const <String>[],
      onStationSelected: (s) => selected = s,
    )));
    await tester.pump();

    final cards = tester.widgetList<TvStationCard>(find.byType(TvStationCard)).toList();
    cards.firstWhere((c) => c.station.slug == 'b').onSelect();
    expect(selected?.slug, 'b');
  });
}
