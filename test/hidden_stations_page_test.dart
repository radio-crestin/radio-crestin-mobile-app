import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/pages/HiddenStationsPage.dart';
import 'package:radio_crestin/services/play_count_service.dart';
import 'package:radio_crestin/services/station_data_service.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/station_factory.dart';

/// Shows a station again the way the app does: no longer hidden.
class _FakeAudioHandler extends BaseAudioHandler implements AppAudioHandler {
  _FakeAudioHandler(this.data);

  final StationDataService data;

  @override
  Future<void> unhideStation(Station station, {bool favorite = false}) =>
      data.setStationIsHidden(station, false);

  @override
  noSuchMethod(Invocation invocation) => null;
}

/// "Readaugă" on the page of hidden stations (Settings → Stații ascunse).
void main() {
  late StationDataService service;

  // No logo URL: the app's placeholder, no network in tests.
  final alpha = StationFactory.createStation(
      id: 1, slug: 'alpha', title: 'Alpha', thumbnailUrl: null);
  final beta = StationFactory.createStation(
      id: 2, slug: 'beta', title: 'Beta', thumbnailUrl: null);

  const explanation = 'Stațiile ascunse nu apar în lista de stații, la '
      'Favorite, în căutare și nici în CarPlay.';
  const empty = 'Nicio stație ascunsă';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await GetIt.instance.reset();
    GetIt.instance
      ..registerSingleton<SharedPreferences>(prefs)
      ..registerSingleton<PlayCountService>(PlayCountService());
    service = StationDataService(
      graphqlClient: GraphQLClient(
        link: HttpLink('https://example.com/graphql'),
        cache: GraphQLCache(),
      ),
    );
    service.applyPublicStationsForTest([alpha, beta]);
    GetIt.instance
      ..registerSingleton<StationDataService>(service)
      ..registerSingleton<AppAudioHandler>(_FakeAudioHandler(service));
  });

  tearDown(() async {
    service.dispose();
    await GetIt.instance.reset();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.dark,
      home: const HiddenStationsPage(),
    ));
    await tester.pumpAndSettle();
  }

  /// How tall [title]'s row is drawn: it folds to 0 on its way out.
  double rowSize(WidgetTester tester, String title) => tester
      .widget<SizeTransition>(find
          .ancestor(of: find.text(title), matching: find.byType(SizeTransition))
          .first)
      .sizeFactor
      .value;

  testWidgets('a station of several folds its row away, then shows',
      (tester) async {
    await service.setStationIsHidden(alpha, true);
    await service.setStationIsHidden(beta, true);
    await pumpPage(tester);

    await tester.tap(find.text('Readaugă').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(rowSize(tester, 'Beta'), inExclusiveRange(0, 1),
        reason: 'the last hidden is listed first, and folds');
    expect(service.hiddenStationSlugs.value, contains('beta'));

    await tester.pumpAndSettle();
    expect(service.hiddenStationSlugs.value, ['alpha']);
    expect(find.text('Beta'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('the last one fades away with the list, never leaving the '
      'text alone, then the empty page fades in', (tester) async {
    await service.setStationIsHidden(alpha, true);
    await pumpPage(tester);

    await tester.tap(find.text('Readaugă'));
    await tester.pump();
    expect(service.hiddenStationSlugs.value, isEmpty,
        reason: 'shown at once, no fold first');

    for (var ms = 0; ms < 300; ms += 30) {
      await tester.pump(const Duration(milliseconds: 30));
      if (find.text(explanation).evaluate().isNotEmpty) {
        expect(find.text('Alpha'), findsOneWidget);
        expect(rowSize(tester, 'Alpha'), 1,
            reason: 'the row leaves with the text, at full height');
      }
    }
    await tester.pumpAndSettle();

    expect(find.text(explanation), findsNothing);
    expect(find.text(empty), findsOneWidget);
  });

  testWidgets('a second tap on "Readaugă" does nothing more', (tester) async {
    await service.setStationIsHidden(alpha, true);
    await service.setStationIsHidden(beta, true);
    await pumpPage(tester);

    final readd = find.text('Readaugă').first;
    await tester.tap(readd);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(readd, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(service.hiddenStationSlugs.value, ['alpha']);
  });
}
