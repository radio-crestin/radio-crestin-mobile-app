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
            id: 'x', title: 'T', message: 'M',
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
            id: 'x', title: 'T', message: 'M',
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

  testWidgets('renders without crashing in dark mode', (tester) async {
    await tester.pumpWidget(
      host(
        PromoNotificationCard(
          notification: const PromoNotification(
            id: 'x', title: 'T', message: 'M',
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
