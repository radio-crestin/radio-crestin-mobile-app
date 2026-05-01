import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/connectivity_banner.dart';

void main() {
  Future<void> pump(WidgetTester tester, ConnectivityBanner banner) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: banner),
      ),
    );
  }

  group('ConnectivityBanner', () {
    testWidgets('renders nothing when online and no back-online flag',
        (tester) async {
      await pump(
        tester,
        const ConnectivityBanner(isOffline: false, showBackOnline: false),
      );
      expect(find.text('Fără conexiune la internet'), findsNothing);
      expect(find.text('Conexiune la internet restabilită'), findsNothing);
      expect(find.byIcon(Icons.wifi), findsNothing);
      expect(find.byIcon(Icons.wifi_off), findsNothing);
    });

    testWidgets('shows offline banner when isOffline is true', (tester) async {
      await pump(
        tester,
        const ConnectivityBanner(isOffline: true, showBackOnline: false),
      );
      expect(find.text('Fără conexiune la internet'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
      expect(find.text('Conexiune la internet restabilită'), findsNothing);
    });

    testWidgets('shows back-online banner when showBackOnline is true',
        (tester) async {
      await pump(
        tester,
        const ConnectivityBanner(isOffline: false, showBackOnline: true),
      );
      expect(find.text('Conexiune la internet restabilită'), findsOneWidget);
      expect(find.byIcon(Icons.wifi), findsOneWidget);
      expect(find.text('Fără conexiune la internet'), findsNothing);
    });

    testWidgets('isOffline takes priority over showBackOnline',
        (tester) async {
      await pump(
        tester,
        const ConnectivityBanner(isOffline: true, showBackOnline: true),
      );
      expect(find.text('Fără conexiune la internet'), findsOneWidget);
      expect(find.text('Conexiune la internet restabilită'), findsNothing);
    });
  });
}
