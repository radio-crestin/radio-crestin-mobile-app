import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/promo_notification_service.dart';
import 'package:radio_crestin/widgets/promo_notification_card.dart';

void main() {
  // SVG asset loading goes through the asset bundle. flutter_svg renders an
  // empty placeholder when the asset is missing, which is fine for tests
  // since we only assert on text/structure.

  Widget host(Widget child, {ThemeMode mode = ThemeMode.light}) {
    return MaterialApp(
      themeMode: mode,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      home: Scaffold(body: child),
    );
  }

  testWidgets('renders title and message', (tester) async {
    await tester.pumpWidget(
      host(
        PromoNotificationCard(
          notification: const PromoNotification(
            id: 'x',
            title: 'My Title',
            message: 'My Message',
          ),
          onDismiss: () {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('My Title'), findsOneWidget);
    expect(find.text('My Message'), findsOneWidget);
  });

  testWidgets('shows "Works with" badges for CarPlay & Android Auto',
      (tester) async {
    await tester.pumpWidget(
      host(
        PromoNotificationCard(
          notification: const PromoNotification(
            id: 'x',
            title: 'T',
            message: 'M',
          ),
          onDismiss: () {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Apple CarPlay'), findsOneWidget);
    expect(find.text('Android Auto'), findsOneWidget);
    expect(find.text('Works with'), findsNWidgets(2));
  });

  testWidgets('tapping the close button calls onDismiss', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      host(
        PromoNotificationCard(
          notification: const PromoNotification(
            id: 'x',
            title: 'T',
            message: 'M',
          ),
          onDismiss: () => dismissed++,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('the close button takes touches up to the card\'s corner',
      (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      host(
        PromoNotificationCard(
          notification: const PromoNotification(
            id: 'x',
            title: 'T',
            message: 'M',
          ),
          onDismiss: () => dismissed++,
        ),
      ),
    );
    await tester.pump();
    final icon = tester.getCenter(find.byIcon(Icons.close));

    // Near the card's top right corner, then below and left of the circle.
    for (final offset in const [
      Offset(20, -20),
      Offset(0, 21),
      Offset(-21, 0),
    ]) {
      await tester.tapAt(icon + offset);
      await tester.pumpAndSettle();
    }

    expect(dismissed, 3);
  });

  group('narrow screens', () {
    const carMessage = PromoNotification(
      id: 'carplay_android_auto_v1',
      title: 'Ascultă Radio Creștin în mașină',
      message: 'Conectează telefonul prin Apple CarPlay sau Android Auto și '
          'bucură-te de toate stațiile tale preferate pe drum.',
    );

    Future<void> pumpCard(
      WidgetTester tester, {
      required double width,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              // Home shows the card at the top of its station list.
              body: CustomScrollView(slivers: [
                SliverToBoxAdapter(
                  child: PromoNotificationCard(
                    notification: carMessage,
                    onDismiss: () {},
                  ),
                ),
              ]),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    Rect badge(WidgetTester tester, String label) => tester.getRect(
          find
              .ancestor(of: find.text(label), matching: find.byType(Container))
              .first,
        );

    // The test font draws every glyph fontSize wide, so the badges need
    // about 420px side by side: more than a phone, unlike Roboto (~280px).
    testWidgets('keeps the badges side by side when they fit', (tester) async {
      await pumpCard(tester, width: 600);

      final carPlay = badge(tester, 'Apple CarPlay');
      final androidAuto = badge(tester, 'Android Auto');
      expect(androidAuto.top, carPlay.top);
      expect(androidAuto.left, greaterThan(carPlay.right));
    });

    // An overflow would fail these tests on its own. 320 is the narrowest
    // phone width; 2.0 is an accessibility text size.
    for (final (width, textScale) in [
      (320.0, 1.0),
      (360.0, 1.3),
      (320.0, 2.0)
    ]) {
      testWidgets(
          'stacks the badges, equally wide, at ${width}px, ${textScale}x text',
          (tester) async {
        await pumpCard(tester, width: width, textScale: textScale);

        final card = tester.getRect(find.byType(PromoNotificationCard));
        final carPlay = badge(tester, 'Apple CarPlay');
        final androidAuto = badge(tester, 'Android Auto');
        expect(androidAuto.top, greaterThan(carPlay.bottom));
        expect(androidAuto.left, carPlay.left);
        expect(androidAuto.width, carPlay.width);
        expect(carPlay.right, lessThanOrEqualTo(card.right - 20));
        expect(androidAuto.right, lessThanOrEqualTo(card.right - 20));
      });
    }

    testWidgets('keeps the title clear of the close button', (tester) async {
      await pumpCard(tester, width: 320);

      final title = tester.getRect(find.text(carMessage.title));
      final close = tester.getRect(find.byIcon(Icons.close));
      expect(title.right, lessThan(close.left));
    });
  });

  testWidgets('renders without crashing in dark mode', (tester) async {
    await tester.pumpWidget(
      host(
        PromoNotificationCard(
          notification: const PromoNotification(
            id: 'x',
            title: 'T',
            message: 'M',
          ),
          onDismiss: () {},
        ),
        mode: ThemeMode.dark,
      ),
    );
    await tester.pump();
    expect(find.text('T'), findsOneWidget);
  });
}
