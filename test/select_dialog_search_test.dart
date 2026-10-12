import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/components/SelectDialog.dart';

void main() {
  const titles = [
    'Radio Flacăra Rusaliilor',
    'Radio Vocea Creștinilor',
    'Radio Vocea Evangheliei - Cluj',
    'Radio Micul Samaritean',
  ];

  Widget buildDialog() {
    return MaterialApp(
      home: Scaffold(
        body: SelectDialog<String>(
          items: titles,
          displayFunction: (String t) => t,
          searchFunction: (String t) => t,
          onItemSelected: (_) {},
        ),
      ),
    );
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextFormField), query);
    await tester.pump();
  }

  group('SelectDialog search', () {
    testWidgets('matches titles typed without diacritics', (tester) async {
      await tester.pumpWidget(buildDialog());
      await tester.pump(const Duration(milliseconds: 150));

      await search(tester, 'flacara');
      expect(find.text('Radio Flacăra Rusaliilor'), findsOneWidget);
      expect(find.text('Radio Micul Samaritean'), findsNothing);

      await search(tester, 'CRESTIN');
      expect(find.text('Radio Vocea Creștinilor'), findsOneWidget);
      expect(find.text('Radio Flacăra Rusaliilor'), findsNothing);
    });

    testWidgets('cedilla and comma-below variants match', (tester) async {
      await tester.pumpWidget(buildDialog());
      await tester.pump(const Duration(milliseconds: 150));

      // 'ş' (cedilla, U+015F) against a title spelled with 'ș' (U+0219).
      await search(tester, 'creştin');
      expect(find.text('Radio Vocea Creștinilor'), findsOneWidget);
    });

    testWidgets('punctuation differences do not block a match',
        (tester) async {
      await tester.pumpWidget(buildDialog());
      await tester.pump(const Duration(milliseconds: 150));

      await search(tester, 'evangheliei cluj');
      expect(find.text('Radio Vocea Evangheliei - Cluj'), findsOneWidget);
    });

    testWidgets('shows the empty state when nothing matches',
        (tester) async {
      await tester.pumpWidget(buildDialog());
      await tester.pump(const Duration(milliseconds: 150));

      await search(tester, 'zzz');
      expect(find.text('Nicio stație găsită.'), findsOneWidget);
    });

    testWidgets('closing before the delayed focus does not throw',
        (tester) async {
      await tester.pumpWidget(buildDialog());
      // Dispose the dialog inside the 100 ms autofocus delay.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(milliseconds: 150));

      expect(tester.takeException(), isNull);
    });
  });
}
