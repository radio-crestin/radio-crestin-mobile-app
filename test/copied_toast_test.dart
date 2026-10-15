import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/copied_toast.dart';

void main() {
  const message = 'Melodie copiată';
  final toast = find.text(message);

  late int taps;

  setUp(() => taps = 0);

  /// Pumps a page whose button fills the bottom of the screen, under where
  /// the toast shows, and returns a context to show the toast from.
  Future<BuildContext> pumpPage(
    WidgetTester tester, {
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 200,
                width: double.infinity,
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('Under the toast'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return tester.element(find.byType(Scaffold));
  }

  double opacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find.ancestor(of: toast, matching: find.byType(Opacity)).first,
      )
      .opacity;

  testWidgets('rises in, stays a moment, then goes away on its own',
      (tester) async {
    final context = await pumpPage(tester);

    CopiedToast.show(context, message: message);
    await tester.pump();
    expect(toast, findsOneWidget);
    expect(opacity(tester), lessThan(0.1));

    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), 1.0);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(toast, findsOneWidget);

    await tester.pump(CopiedToastView.lifetime);
    await tester.pump();
    expect(toast, findsNothing);
  });

  testWidgets('starts below its place and springs up to it', (tester) async {
    final context = await pumpPage(tester);

    CopiedToast.show(context, message: message);
    await tester.pump();
    final start = tester.getCenter(toast).dy;
    await tester.pump(const Duration(milliseconds: 600));
    final end = tester.getCenter(toast).dy;

    expect(start, greaterThan(end));
  });

  testWidgets('with reduced motion it only fades', (tester) async {
    final context = await pumpPage(tester, reduceMotion: true);

    CopiedToast.show(context, message: message);
    await tester.pump(const Duration(milliseconds: 16));
    final start = tester.getCenter(toast).dy;
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.getCenter(toast).dy, start);
  });

  testWidgets('sits as high as asked, in a plain text style',
      (tester) async {
    final context = await pumpPage(tester);
    final screenHeight = tester.view.physicalSize.height /
        tester.view.devicePixelRatio;

    CopiedToast.show(context, message: message, bottom: 150);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final card = find
        .ancestor(of: toast, matching: find.byType(DecoratedBox))
        .first;
    expect(screenHeight - tester.getRect(card).bottom, closeTo(150, 0.5));
    // Without a Material above it, the text would get Flutter's yellow
    // underline for unstyled text.
    final text = tester.widget<RichText>(
      find.descendant(of: card, matching: find.byType(RichText)),
    );
    expect(text.text.style?.decoration, isNot(TextDecoration.underline));

    await tester.pump(CopiedToastView.lifetime);
  });

  testWidgets('a new toast replaces the one on screen', (tester) async {
    final context = await pumpPage(tester);

    CopiedToast.show(context, message: message);
    await tester.pump(const Duration(milliseconds: 500));
    CopiedToast.show(context, message: message);
    await tester.pump(const Duration(milliseconds: 500));

    expect(toast, findsOneWidget);

    // The first one's end must not take the second one away early.
    await tester.pump(const Duration(milliseconds: 1200));
    expect(toast, findsOneWidget);

    await tester.pump(CopiedToastView.lifetime);
    await tester.pump();
    expect(toast, findsNothing);
  });

  testWidgets('touches go through to what is under it', (tester) async {
    final context = await pumpPage(tester);

    CopiedToast.show(context, message: message);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(toast, warnIfMissed: false);

    expect(taps, 1);
    await tester.pump(CopiedToastView.lifetime);
  });

  testWidgets('screen readers hear it', (tester) async {
    final handle = tester.ensureSemantics();
    final context = await pumpPage(tester);

    CopiedToast.show(context, message: message);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getSemantics(toast),
      isSemantics(label: message, isLiveRegion: true),
    );

    await tester.pump(CopiedToastView.lifetime);
    handle.dispose();
  });
}
