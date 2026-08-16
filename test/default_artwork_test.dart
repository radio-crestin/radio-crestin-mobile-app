import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/default_artwork.dart';

/// Renders [DefaultArtwork] inside a sized, themed scaffold and returns the
/// tester so assertions can inspect it.
Widget _host({required ThemeData theme, IconData? icon}) {
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: icon == null
              ? const DefaultArtwork()
              : DefaultArtwork(icon: icon),
        ),
      ),
    ),
  );
}

void main() {
  group('DefaultArtwork', () {
    testWidgets('renders a branded gradient tile with a glyph in light theme',
        (tester) async {
      await tester.pumpWidget(_host(theme: lightTheme));
      await tester.pump();

      expect(find.byType(DefaultArtwork), findsOneWidget);
      // Default glyph is the music note.
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);

      // A brand gradient (not a flat error box) backs the tile.
      final decorated = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(DefaultArtwork),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = decorated.decoration as BoxDecoration;
      final gradient = decoration.gradient as LinearGradient;
      expect(gradient.colors, contains(AppColors.primary));
    });

    testWidgets('renders with a deeper gradient in dark theme', (tester) async {
      await tester.pumpWidget(_host(theme: darkTheme));
      await tester.pump();

      expect(find.byType(DefaultArtwork), findsOneWidget);
      final decorated = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(DefaultArtwork),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = decorated.decoration as BoxDecoration;
      final gradient = decoration.gradient as LinearGradient;
      // Dark variant leads with the dark brand tone.
      expect(gradient.colors.first, AppColors.primaryDark);
    });

    testWidgets('honors a custom (type-appropriate) glyph', (tester) async {
      await tester.pumpWidget(
          _host(theme: lightTheme, icon: Icons.movie_outlined));
      await tester.pump();

      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      expect(find.byIcon(Icons.music_note_rounded), findsNothing);
    });
  });
}
