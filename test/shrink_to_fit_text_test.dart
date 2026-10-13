import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/shrink_to_fit_text.dart';

// The test font draws every glyph exactly fontSize wide, so in a 300px box a
// title of n characters fits at 300 / n px. No letter spacing keeps that
// exact (the Material body style adds some).
const _style =
    TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 0);
const _short = 'Cu mine Tu'; // 10 chars: 220px at 22px, fits.
const _longer = 'Domnul va purta'; // 15 chars: fits at 20px.
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

Widget _title(String text) =>
    ShrinkToFitText(text, style: _style, minFontSize: 17);

Text _rendered(WidgetTester tester) => tester.widget<Text>(find.descendant(
      of: find.byType(ShrinkToFitText),
      matching: find.byType(Text),
    ));

void main() {
  group('ShrinkToFitText', () {
    testWidgets('keeps the full size when the text fits', (tester) async {
      await tester.pumpWidget(_host(_title(_short)));

      expect(_rendered(tester).style!.fontSize, 22);
    });

    testWidgets('shrinks to the largest size that fits', (tester) async {
      await tester.pumpWidget(_host(_title(_longer)));

      expect(_rendered(tester).style!.fontSize, 20);
      expect(tester.getSize(find.text(_longer)).width, lessThanOrEqualTo(300));
    });

    testWidgets('stops at the minimum size and ends in an ellipsis',
        (tester) async {
      await tester.pumpWidget(_host(_title(_veryLong)));

      final text = _rendered(tester);
      expect(text.style!.fontSize, 17);
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('is one line tall at the full size whatever the text',
        (tester) async {
      final heights = <double>[];
      for (final text in ['', _short, _longer, _veryLong]) {
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
      for (final title in ['', _short, _longer, _veryLong]) {
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
