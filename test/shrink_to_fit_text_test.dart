import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/shrink_to_fit_text.dart';

// The test font draws every glyph exactly fontSize wide, so in a 300px box a
// line holds 300 / fontSize characters. No letter spacing keeps that exact
// (the Material body style adds some).
const _style =
    TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 0);
const _short = 'Cu mine Tu'; // 10 chars: 220px at 22px, fits.
const _longer = 'Domnul va purta'; // 15 chars: fits on one line at 20px.
// 28 chars: too wide for one line at 17px, two lines at 17px.
const _twoLines = 'Plinatate si bucurie in ziua';
// Two 18-char lines: they need 16.5px (18 * 17 = 306px is too wide).
const _twoSmallLines = 'Eclesiastul - 04 _ Cum sa fii fericit';
// Three lines even at 15px.
const _veryLong = 'Eclesiastul - 04 _ Cum sa fii fericit sub soare I';

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Center(child: SizedBox(width: 300, child: child)),
          ),
        ),
      ),
    );

Widget _title(String text, {bool wrap = true}) => ShrinkToFitText(
      text,
      style: _style,
      minFontSize: 17,
      twoLineMinFontSize: wrap ? 15 : null,
    );

Text _rendered(WidgetTester tester) => tester.widget<Text>(find.descendant(
      of: find.byType(ShrinkToFitText),
      matching: find.byType(Text),
    ));

void main() {
  group('ShrinkToFitText', () {
    testWidgets('keeps the full size when the text fits', (tester) async {
      await tester.pumpWidget(_host(_title(_short)));

      final text = _rendered(tester);
      expect(text.style!.fontSize, 22);
      expect(text.maxLines, 1);
    });

    testWidgets('shrinks one line to the largest size that fits',
        (tester) async {
      await tester.pumpWidget(_host(_title(_longer)));

      expect(_rendered(tester).style!.fontSize, 20);
      expect(tester.getSize(find.text(_longer)).width, lessThanOrEqualTo(300));
    });

    testWidgets('wraps to two lines at the one-line minimum', (tester) async {
      await tester.pumpWidget(_host(_title(_twoLines)));

      final text = _rendered(tester);
      expect(text.style!.fontSize, 17);
      expect(text.maxLines, 2);
    });

    testWidgets('shrinks the two lines when they need it', (tester) async {
      await tester.pumpWidget(_host(_title(_twoSmallLines)));

      final text = _rendered(tester);
      expect(text.style!.fontSize, 16.5);
      expect(text.maxLines, 2);
    });

    testWidgets('ends in an ellipsis only past the two-line minimum',
        (tester) async {
      await tester.pumpWidget(_host(_title(_veryLong)));

      final text = _rendered(tester);
      expect(text.style!.fontSize, 15);
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('without wrapping, stops at the minimum with an ellipsis',
        (tester) async {
      await tester.pumpWidget(_host(_title(_veryLong, wrap: false)));

      final text = _rendered(tester);
      expect(text.style!.fontSize, 17);
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('keeps the same height whatever the text', (tester) async {
      final heights = <double>[];
      for (final text in ['', _short, _longer, _twoLines, _veryLong]) {
        await tester.pumpWidget(_host(_title(text)));
        heights.add(tester.getSize(find.byType(ShrinkToFitText)).height);
      }

      expect(heights.toSet(), hasLength(1));
      expect(heights.first, greaterThan(0));
    });

    testWidgets(
        'keeps the line below in place whatever the title '
        '(regression: a two-line title pushed the player controls down)',
        (tester) async {
      const below = Key('below');
      final positions = <double>[];
      for (final title in ['', _short, _longer, _twoLines, _veryLong]) {
        await tester.pumpWidget(_host(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _title(title),
            const Text('Lazar Gog'),
            const SizedBox(key: below, height: 10),
          ],
        )));
        positions.add(tester.getTopLeft(find.byKey(below)).dy);
      }

      expect(positions.toSet(), hasLength(1));
    });

    testWidgets('sits a single line at the bottom of the slot', (tester) async {
      await tester.pumpWidget(_host(_title(_short)));

      expect(
        tester.getBottomLeft(find.text(_short)).dy,
        tester.getBottomLeft(find.byType(ShrinkToFitText)).dy,
      );
    });

    testWidgets('fits the scaled text when the system text size is larger',
        (tester) async {
      // 10 chars at 22px * 1.5 = 330px, too wide; at 20px * 1.5 = 300px.
      await tester.pumpWidget(_host(_title(_short), textScale: 1.5));

      expect(_rendered(tester).style!.fontSize, 20);
    });

    testWidgets('gives screen readers the whole title', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(_title(_veryLong)));

      expect(find.bySemanticsLabel(_veryLong), findsOneWidget);
      semantics.dispose();
    });
  });
}
