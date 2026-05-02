import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/widgets/review_modal.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(brightness: Brightness.light, useMaterial3: true),
    home: Scaffold(body: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    GetIt.instance.reset();
    GetIt.instance.registerSingleton<SharedPreferences>(prefs);
  });

  tearDown(() => GetIt.instance.reset());

  group('ReviewModal — header rendering', () {
    testWidgets('shows the heading and station title', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'RVE Timisoara',
      )));

      expect(find.text('Adaugă o recenzie'), findsOneWidget);
      expect(find.text('RVE Timisoara'), findsOneWidget);
    });

    testWidgets('shows song row "title - artist" when both provided', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
        songTitle: 'Lauda',
        songArtist: 'Sunny',
      )));

      expect(find.text('Lauda - Sunny'), findsOneWidget);
      // Music note icon is the visual indicator that the song row is present.
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });

    testWidgets('shows just the song title when artist is empty', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
        songTitle: 'Lauda',
        songArtist: '',
      )));

      expect(find.text('Lauda'), findsOneWidget);
    });

    testWidgets('hides the song row entirely when songTitle is null', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
      )));

      expect(find.byIcon(Icons.music_note_rounded), findsNothing);
    });

    testWidgets('hides the song row when songTitle is an empty string', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
        songTitle: '',
      )));

      expect(find.byIcon(Icons.music_note_rounded), findsNothing);
    });
  });

  group('ReviewModal — interactive controls', () {
    testWidgets('exposes a close button (X icon)', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
      )));

      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('shows a 500-char message input with character counter', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
      )));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('0/500'), findsOneWidget);
    });

    testWidgets('character counter updates as the user types', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
      )));

      await tester.enterText(find.byType(TextField), 'Salut');
      await tester.pump();

      expect(find.text('5/500'), findsOneWidget);
    });

    testWidgets('renders the primary submit button labeled "Trimite mesajul"', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
      )));

      expect(find.widgetWithText(FilledButton, 'Trimite mesajul'), findsOneWidget);
    });

    testWidgets('submit button is enabled by default (idle state)', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
      )));

      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Trimite mesajul'),
      );
      expect(btn.onPressed, isNotNull);
    });
  });

  group('ReviewModal — disclaimer text', () {
    testWidgets('shows the visibility disclaimer (Romanian)', (tester) async {
      await tester.pumpWidget(_wrap(const ReviewModal(
        stationId: 1,
        stationTitle: 'S',
      )));

      expect(
        find.text(
          'Recenziile vor fi vizibile tuturor utilizatorilor aplicației.',
        ),
        findsOneWidget,
      );
    });
  });
}
