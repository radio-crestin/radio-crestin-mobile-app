import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/hide_station_dialog.dart';

import 'helpers/station_factory.dart';

void main() {
  final station = StationFactory.createStation(
    id: 7,
    slug: 'rve-sibiu',
    title: 'RVE Sibiu',
  );

  const bothPlatforms = TargetPlatformVariant(
    {TargetPlatform.iOS, TargetPlatform.android},
  );

  /// Opens the dialog and returns what it resolves to once [answer] is
  /// tapped.
  Future<bool?> answerWith(WidgetTester tester, String answer) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await confirmHideFavoriteStation(context, station),
          child: const Text('Open'),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Ascunzi „RVE Sibiu”?'), findsOneWidget);
    expect(find.textContaining('va fi scoasă din Favorite'), findsOneWidget);
    expect(find.textContaining('Setări → Stații ascunse'), findsOneWidget);

    await tester.tap(find.text(answer));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('"Ascunde" confirms', (tester) async {
    expect(await answerWith(tester, 'Ascunde'), isTrue);
  }, variant: bothPlatforms);

  testWidgets('"Anulează" keeps the station', (tester) async {
    expect(await answerWith(tester, 'Anulează'), isFalse);
  }, variant: bothPlatforms);

  testWidgets('names the car of the platform', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => confirmHideFavoriteStation(context, station),
          child: const Text('Open'),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final car = debugDefaultTargetPlatformOverride == TargetPlatform.iOS
        ? 'CarPlay'
        : 'Android Auto';
    expect(find.textContaining('nici în $car'), findsOneWidget);
  }, variant: bothPlatforms);
}
