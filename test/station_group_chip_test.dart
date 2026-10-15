import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/station_group_chip.dart';

import 'helpers/station_factory.dart';

void main() {
  final copii =
      StationFactory.createStationGroup(id: 9, name: 'Copii', slug: 'copii');
  late int presses;
  late int clears;

  setUp(() {
    presses = 0;
    clears = 0;
  });

  Future<void> pumpChip(WidgetTester tester, {ThemeData? theme}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: theme ?? darkTheme,
        home: Scaffold(
          body: Center(
            child: StationGroupChip(
              group: copii,
              onPressed: () => presses++,
              onCleared: () => clears++,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the category with its picture', (tester) async {
    await pumpChip(tester);

    expect(find.text('Copii'), findsOneWidget);
    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(
      (picture.bytesLoader as SvgAssetLoader).assetName,
      'assets/icons/station_groups/copii.svg',
    );
  });

  testWidgets('a tap on the name opens the filter', (tester) async {
    await pumpChip(tester);

    await tester.tap(find.text('Copii'));

    expect(presses, 1);
    expect(clears, 0);
  });

  testWidgets('a tap on the cross clears the filter', (tester) async {
    await pumpChip(tester);

    await tester.tap(find.byIcon(Icons.close_rounded));

    expect(clears, 1);
    expect(presses, 0);
  });

  testWidgets('keeps its size while the app switches theme', (tester) async {
    Widget app(ThemeMode mode) => MaterialApp(
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: mode,
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: StationGroupChip(
                group: copii,
                onPressed: () {},
                onCleared: () {},
              ),
            ),
          ),
        );
    Rect chip() => tester.getRect(find.byType(StationGroupChip));

    await tester.pumpWidget(app(ThemeMode.dark));
    final atRest = chip();

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await tester.pumpWidget(app(mode));
      // MaterialApp animates between the two themes for 200 ms.
      for (var ms = 0; ms <= 250; ms += 25) {
        expect(chip(), atRest, reason: '${mode.name} theme, $ms ms in');
        await tester.pump(const Duration(milliseconds: 25));
      }
    }
  });

  testWidgets('sets its name in the same type in both themes', (tester) async {
    TextStyle? labelStyle() => tester
        .widget<RichText>(find.descendant(
          of: find.text('Copii'),
          matching: find.byType(RichText),
        ))
        .text
        .style;

    await pumpChip(tester, theme: darkTheme);
    final dark = labelStyle();
    await pumpChip(tester, theme: lightTheme);
    await tester.pumpAndSettle();
    final light = labelStyle();

    // The test font can't show where the glyphs sit, so compare what
    // places them: on iOS a missing even leading moves the text 1 pt.
    expect(light?.inherit, dark?.inherit);
    expect(light?.fontFamily, dark?.fontFamily);
    expect(light?.fontSize, dark?.fontSize);
    expect(light?.fontWeight, dark?.fontWeight);
    expect(light?.letterSpacing, dark?.letterSpacing);
    expect(light?.height, dark?.height);
    expect(light?.leadingDistribution, dark?.leadingDistribution);
    expect(light?.textBaseline, dark?.textBaseline);
  });

  testWidgets('the cross tells screen readers what it does', (tester) async {
    await pumpChip(tester, theme: lightTheme);

    expect(find.byTooltip('Arată toate stațiile'), findsOneWidget);
    expect(find.byTooltip('Schimbă categoria'), findsOneWidget);
  });
}
