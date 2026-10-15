import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/station_group_filter_sheet.dart';

import 'helpers/station_factory.dart';

Query$GetStations$station_groups _group(
  int id,
  String slug,
  String name, {
  int order = 0,
  required List<int> stationIds,
}) =>
    StationFactory.createStationGroup(
      id: id,
      name: name,
      slug: slug,
      order: order,
      stationToStationGroups: [
        for (final s in stationIds)
          StationFactory.createStationToStationGroup(stationId: s),
      ],
    );

final _stations = [
  StationFactory.createStation(
      id: 1, slug: 'a', title: 'A', totalListeners: 1000),
  StationFactory.createStation(
      id: 2, slug: 'b', title: 'B', totalListeners: 300),
  StationFactory.createStation(
      id: 3, slug: 'c', title: 'C', totalListeners: 60),
];

final _all = _group(1, 'radio', 'Toate', order: -1, stationIds: [1, 2, 3]);
final _muzica = _group(2, 'muzica', 'Muzica', order: 1, stationIds: [1, 2]);
final _worship = _group(3, 'worship', 'Worship', order: 2, stationIds: [3]);
final _newCategory =
    _group(4, 'nou', 'Categorie nouă', order: 3, stationIds: [2]);
final _groups = [_all, _muzica, _worship, _newCategory];

void main() {
  late List<Query$GetStations$station_groups?> chosen;

  setUp(() => chosen = []);

  Future<void> openSheet(
    WidgetTester tester, {
    Query$GetStations$station_groups? selected,
    ThemeData? theme,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? darkTheme,
        // Above the navigator, so the sheet's route gets the text size too.
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => StationGroupFilterSheet.show(
                  context,
                  groups: _groups,
                  stations: _stations,
                  selected: selected,
                  onSelected: chosen.add,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  String? assetOf(SvgPicture picture) {
    final loader = picture.bytesLoader;
    return loader is SvgAssetLoader ? loader.assetName : null;
  }

  testWidgets('shows every station, then the categories with their counts',
      (tester) async {
    await openSheet(tester);

    expect(find.text('Toate stațiile'), findsOneWidget);
    expect(find.text('3 stații · 1.360 ascultă acum'), findsOneWidget);
    expect(find.text('Muzica'), findsOneWidget);
    expect(find.text('2 stații'), findsOneWidget);
    expect(find.text('Worship'), findsOneWidget);
    expect(find.text('1 stație'), findsNWidgets(2),
        reason: 'Worship and the new category');
    expect(find.text('Toate'), findsNothing,
        reason: 'the API group with every station repeats "Toate stațiile"');
    expect(find.text('Resetează'), findsNothing);
  });

  testWidgets('a category without its own picture gets the fallback one',
      (tester) async {
    await openSheet(tester);

    final assets = tester
        .widgetList<SvgPicture>(find.byType(SvgPicture))
        .map(assetOf)
        .toList();
    expect(assets, [
      'assets/icons/station_groups/all.svg',
      'assets/icons/station_groups/muzica.svg',
      'assets/icons/station_groups/worship.svg',
      'assets/icons/station_groups/fallback.svg',
    ]);
  });

  testWidgets('one tap on a category chooses it and closes the sheet',
      (tester) async {
    await openSheet(tester);

    await tester.tap(find.text('Worship'));
    await tester.pumpAndSettle();

    expect(chosen, [_worship]);
    expect(find.text('Filtrează stații'), findsNothing);
  });

  testWidgets('"Resetează" shows while a category is chosen and clears it',
      (tester) async {
    await openSheet(tester, selected: _muzica);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Muzica, 2 stații')),
      matchesSemantics(
        label: 'Muzica, 2 stații',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(find.text('Resetează'));
    await tester.pumpAndSettle();

    expect(chosen, [null]);
    expect(find.text('Filtrează stații'), findsNothing);
  });

  testWidgets('tapping the chosen category again shows every station',
      (tester) async {
    await openSheet(tester, selected: _worship);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Worship, 1 stație')),
      matchesSemantics(
        label: 'Worship, 1 stație',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
        onTapHint: 'arată toate stațiile',
      ),
    );

    await tester.tap(find.text('Worship'));
    await tester.pumpAndSettle();

    expect(chosen, [null]);
    expect(find.text('Filtrează stații'), findsNothing);
  });

  testWidgets('the hidden "all" group counts as every station',
      (tester) async {
    await openSheet(tester, selected: _all);

    expect(find.text('Resetează'), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel(RegExp('^Toate stațiile'))),
      matchesSemantics(
        label: 'Toate stațiile, 3 stații · 1.360 ascultă acum',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
  });

  for (final (name, theme) in [('dark', darkTheme), ('light', lightTheme)]) {
    testWidgets('fits at twice the text size ($name theme)', (tester) async {
      await openSheet(tester, theme: theme, textScale: 2);

      expect(tester.takeException(), isNull);
      expect(find.text('Muzica'), findsOneWidget);
    });
  }

  test('every category hue has a picture in the assets', () {
    for (final slug in [
      ...AppColors.stationGroupHues.keys,
      'all',
      'fallback',
    ]) {
      expect(
        File('assets/icons/station_groups/$slug.svg').existsSync(),
        isTrue,
        reason: slug,
      );
    }
  });
}
