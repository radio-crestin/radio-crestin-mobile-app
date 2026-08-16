import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/local_network_explainer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('LocalNetworkExplainerGate', () {
    late SharedPreferences prefs;
    late int discoveryStarts;

    /// Pumps a screen whose only button runs the gate. [discoveryStarts] is the
    /// fake discovery seam — no Cast plugin is involved.
    Future<void> pumpGate(
      WidgetTester tester, {
      Map<String, Object> initial = const {},
      bool promptsForLocalNetwork = true,
    }) async {
      SharedPreferences.setMockInitialValues(initial);
      prefs = await SharedPreferences.getInstance();
      discoveryStarts = 0;
      final gate = LocalNetworkExplainerGate(
        prefs: prefs,
        startDiscovery: () => discoveryStarts++,
        promptsForLocalNetwork: promptsForLocalNetwork,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => gate.requestDiscovery(context),
              child: const Text('cast'),
            ),
          ),
        ),
      ));
    }

    Future<void> tapCast(WidgetTester tester) async {
      await tester.tap(find.text('cast'));
      await tester.pumpAndSettle();
    }

    testWidgets('first tap explains before any discovery starts',
        (tester) async {
      await pumpGate(tester);

      await tapCast(tester);

      expect(find.text('Redare pe alte dispozitive'), findsOneWidget);
      expect(find.textContaining('rețeaua locală'), findsOneWidget);
      expect(find.text('Continuă'), findsOneWidget);
      expect(find.text('Nu acum'), findsOneWidget);
      expect(discoveryStarts, 0);
    });

    testWidgets('"Nu acum" starts nothing and keeps the explainer pending',
        (tester) async {
      await pumpGate(tester);
      await tapCast(tester);

      await tester.tap(find.text('Nu acum'));
      await tester.pumpAndSettle();

      expect(find.text('Redare pe alte dispozitive'), findsNothing);
      expect(discoveryStarts, 0);
      expect(localNetworkExplainerAcknowledged(prefs), isFalse);
    });

    testWidgets('"Continuă" starts discovery and is remembered',
        (tester) async {
      await pumpGate(tester);
      await tapCast(tester);

      await tester.tap(find.text('Continuă'));
      await tester.pumpAndSettle();

      expect(discoveryStarts, 1);
      expect(localNetworkExplainerAcknowledged(prefs), isTrue);
    });

    testWidgets('a later tap skips the dialog and goes straight to discovery',
        (tester) async {
      await pumpGate(tester, initial: {localNetworkExplainerAckKey: true});

      await tapCast(tester);

      expect(find.text('Redare pe alte dispozitive'), findsNothing);
      expect(discoveryStarts, 1);
    });

    testWidgets('the same session keeps casting without re-explaining',
        (tester) async {
      await pumpGate(tester);
      await tapCast(tester);
      await tester.tap(find.text('Continuă'));
      await tester.pumpAndSettle();

      await tapCast(tester);

      expect(find.text('Redare pe alte dispozitive'), findsNothing);
      expect(discoveryStarts, 2);
    });

    testWidgets('platforms without a local-network prompt never explain',
        (tester) async {
      await pumpGate(tester, promptsForLocalNetwork: false);

      await tapCast(tester);

      expect(find.text('Redare pe alte dispozitive'), findsNothing);
      expect(discoveryStarts, 1);
      expect(localNetworkExplainerAcknowledged(prefs), isFalse);
    });

    testWidgets('discovery is never blocked when preferences are missing',
        (tester) async {
      discoveryStarts = 0;
      final gate = LocalNetworkExplainerGate(
        prefs: null,
        startDiscovery: () => discoveryStarts++,
        promptsForLocalNetwork: true,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => gate.requestDiscovery(context),
              child: const Text('cast'),
            ),
          ),
        ),
      ));

      await tapCast(tester);

      expect(find.text('Redare pe alte dispozitive'), findsNothing);
      expect(discoveryStarts, 1);
    });
  });
}
