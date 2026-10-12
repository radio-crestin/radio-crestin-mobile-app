import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/marquee_text.dart';

// The test font draws every glyph fontSize wide, so at 22px a 300px box fits
// 13 characters.
const _style = TextStyle(fontSize: 22, fontWeight: FontWeight.w600);
const _short = 'De Mana Tu';
const _long = 'Claritatea sfarsitului in profetii-partea intii';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Center(child: SizedBox(width: 300, child: child)),
          ),
        ),
      ),
    );

/// Horizontal scroll offset of the overflowing line (0 at rest).
double _scrollOffset(WidgetTester tester) => tester
    .widget<Transform>(find.descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(Transform),
    ))
    .transform
    .getTranslation()
    .x;

void main() {
  group('MarqueeText', () {
    testWidgets('is one line tall for empty, short and long text',
        (tester) async {
      final heights = <double>[];
      for (final text in ['', _short, _long]) {
        await tester.pumpWidget(_host(MarqueeText(text, style: _style)));
        heights.add(tester.getSize(find.byType(MarqueeText)).height);
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
      for (final title in ['', _short, _long]) {
        await tester.pumpWidget(_host(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MarqueeText(title, style: _style),
            const Text('Lazar Gog'),
            const SizedBox(key: below, height: 10),
          ],
        )));
        positions.add(tester.getTopLeft(find.byKey(below)).dy);
      }

      expect(positions.toSet(), hasLength(1));
    });

    testWidgets('shows text that fits once and never scrolls it',
        (tester) async {
      await tester.pumpWidget(_host(const MarqueeText(_short, style: _style)));
      await tester.pump(const Duration(seconds: 10));

      expect(find.text(_short), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MarqueeText),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
    });

    testWidgets('scrolls overflowing text after a pause, then loops',
        (tester) async {
      await tester.pumpWidget(_host(const MarqueeText(_long, style: _style)));
      await tester.pump();
      expect(_scrollOffset(tester), 0);

      await tester.pump(const Duration(milliseconds: 2400));
      expect(_scrollOffset(tester), 0, reason: 'still resting');

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 1));
      expect(_scrollOffset(tester), lessThan(0));

      // One loop is the text width (47 * 22) plus the 48px gap at 35px/s.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(_scrollOffset(tester), 0, reason: 'back at rest after a loop');

      await tester.pump(const Duration(milliseconds: 2600));
      await tester.pump(const Duration(seconds: 1));
      expect(_scrollOffset(tester), lessThan(0), reason: 'scrolls again');
    });

    testWidgets('stays still when animate is false', (tester) async {
      await tester.pumpWidget(
          _host(const MarqueeText(_long, style: _style, animate: false)));
      await tester.pump(const Duration(seconds: 6));

      expect(_scrollOffset(tester), 0);
    });

    testWidgets('stays still when the platform asks to reduce motion',
        (tester) async {
      await tester.pumpWidget(_host(
        const MarqueeText(_long, style: _style),
        disableAnimations: true,
      ));
      await tester.pump(const Duration(seconds: 6));

      expect(_scrollOffset(tester), 0);
    });

    testWidgets('starts scrolling once animate turns on', (tester) async {
      await tester.pumpWidget(
          _host(const MarqueeText(_long, style: _style, animate: false)));
      await tester.pump(const Duration(seconds: 3));

      await tester.pumpWidget(_host(const MarqueeText(_long, style: _style)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2600));
      await tester.pump(const Duration(seconds: 1));

      expect(_scrollOffset(tester), lessThan(0));
    });

    testWidgets('exposes overflowing text to screen readers once',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(const MarqueeText(_long, style: _style)));

      expect(find.text(_long), findsNWidgets(2), reason: 'drawn twice');
      expect(find.bySemanticsLabel(_long), findsOneWidget);
      semantics.dispose();
    });
  });
}
