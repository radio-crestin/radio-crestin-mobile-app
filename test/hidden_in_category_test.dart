import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/widgets/station_actions_menu.dart';
import 'package:radio_crestin/widgets/station_row_transition.dart';
import 'package:rxdart/rxdart.dart';

import 'helpers/station_factory.dart';

class _FakeData extends Fake implements StationDataService {
  @override
  final BehaviorSubject<List<String>> favoriteStationSlugs =
      BehaviorSubject.seeded(const []);
}

/// Hides a station the way the app does, and remembers which.
class _FakeAudioHandler extends Fake implements AppAudioHandler {
  final hidden = <String>[];

  @override
  final StationDataService stationDataService = _FakeData();

  @override
  int? hideStation(Station station) {
    hidden.add(station.slug);
    return null;
  }
}

/// A category whose stations are all hidden lists them in their places,
/// dimmed, each with "Readaugă".
void main() {
  late _FakeAudioHandler handler;
  late StationRowTransitions transitions;
  late List<String> shownAgain;

  Station station(int id) => StationFactory.createStation(
      id: id, slug: 's$id', title: 'Station $id', thumbnailUrl: null);
  final stations = [for (var id = 1; id <= 3; id++) station(id)];

  setUp(() {
    handler = _FakeAudioHandler();
    transitions = StationRowTransitions();
    shownAgain = [];
  });
  tearDown(() => transitions.dispose());

  Widget list(Set<String>? shownHidden, {bool hidesInPlace = false}) =>
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [
            StationsList(
              stations: stations,
              audioHandler: handler,
              panelController: null,
              favoriteSlugs: const [],
              rowTransitions: transitions,
              shownHidden: shownHidden,
              hidesInPlace: hidesInPlace,
              onShowHidden: (s) => shownAgain.add(s.slug),
            ),
          ]),
        ),
      );

  Finder rowOf(String title) => find.ancestor(
        of: find.text(title),
        matching: find.byType(StationRowTransition),
      );

  Future<void> hideFromMenu(WidgetTester tester, String title) async {
    await tester.longPress(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text(StationActionsMenu.hideLabel));
    await tester.pump();
  }

  testWidgets('a hidden station is listed dimmed, with "Readaugă", and '
      'plays nothing', (tester) async {
    await tester.pumpWidget(list({'s2'}));

    expect(find.text('Ascunsă'), findsOneWidget);
    expect(find.text('Readaugă'), findsOneWidget);
    expect(
      tester.getSize(rowOf('Station 2')),
      tester.getSize(rowOf('Station 1')),
      reason: 'in a slot like the others',
    );

    await tester.tap(find.text('Readaugă'));
    expect(shownAgain, ['s2']);

    await tester.longPress(find.text('Station 2'));
    await tester.pumpAndSettle();
    expect(find.text(StationActionsMenu.hideLabel), findsNothing,
        reason: 'no menu');
  });

  testWidgets('added back, its row fades into the station on show',
      (tester) async {
    await tester.pumpWidget(list({'s2'}));
    final slot = tester.getSize(rowOf('Station 2'));

    await tester.pumpWidget(list(const {}));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('Ascunsă'), findsOneWidget, reason: 'fading out');
    expect(find.text('Station 2'), findsNWidgets(2), reason: 'both looks');
    expect(tester.getSize(rowOf('Station 2').first), slot);

    await tester.pumpAndSettle();
    expect(find.text('Ascunsă'), findsNothing);
    expect(find.text('Station 2'), findsOneWidget);
  });

  testWidgets('hidden where hidden stations are listed, it dims in place '
      'at once', (tester) async {
    await tester.pumpWidget(list(const {}, hidesInPlace: true));

    await hideFromMenu(tester, 'Station 3');

    expect(handler.hidden, ['s3'], reason: 'no row playing out first');
    expect(transitions.isLeaving('s3'), isFalse);
  });

  testWidgets('elsewhere its row plays out first', (tester) async {
    await tester.pumpWidget(list(null));

    await hideFromMenu(tester, 'Station 3');
    expect(handler.hidden, isEmpty);
    expect(transitions.isLeaving('s3'), isTrue);

    await tester.pumpAndSettle();
    expect(handler.hidden, ['s3']);
  });

  group('the line above them', () {
    test('says all are hidden', () {
      expect(hiddenInCategoryText('Worship', hidden: 4, total: 4),
          'Toate cele 4 stații din Worship sunt ascunse.');
      expect(hiddenInCategoryText('Copii', hidden: 23, total: 23),
          'Toate cele 23 de stații din Copii sunt ascunse.');
      expect(hiddenInCategoryText('Biblia', hidden: 1, total: 1),
          'Singura stație din Biblia e ascunsă.');
    });

    test('counts the ones left once some are added back', () {
      expect(hiddenInCategoryText('Worship', hidden: 3, total: 4),
          '3 stații din Worship sunt ascunse.');
      expect(hiddenInCategoryText('Worship', hidden: 1, total: 4),
          'O stație din Worship e ascunsă.');
      expect(hiddenInCategoryText('Worship', hidden: 0, total: 4), isNull);
    });
  });
}
