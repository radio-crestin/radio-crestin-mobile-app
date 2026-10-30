import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/tv/desktop/desktop_station_actions.dart';
import 'package:radio_crestin/tv/tv_theme.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/widgets/hide_station_dialog.dart';

import 'helpers/station_factory.dart';

/// The phone's and the desktop's question before hiding a favorite read
/// from one wording.
void main() {
  final station = StationFactory.createStation(
    id: 7,
    slug: 'rve-sibiu',
    title: 'RVE Sibiu',
  );

  /// Opens [confirm]'s dialog and returns what it resolves to once
  /// [answer] is tapped, after [check] looked at it.
  Future<bool?> open(
    WidgetTester tester, {
    required Future<bool> Function(BuildContext, Station) confirm,
    required String answer,
    ThemeData? theme,
    void Function()? check,
  }) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await confirm(context, station),
          child: const Text('Open'),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    check?.call();
    await tester.tap(find.text(answer));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('the phone\'s dialog reads as before, naming its car screen',
      (tester) async {
    final car = debugDefaultTargetPlatformOverride == TargetPlatform.iOS
        ? 'CarPlay'
        : 'Android Auto';
    final confirmed = await open(
      tester,
      confirm: confirmHideFavoriteStation,
      answer: 'Ascunde',
      check: () {
        expect(find.text('Ascunzi „RVE Sibiu”?'), findsOneWidget);
        expect(
          find.text(
            'Stația este la Favorite. Dacă o ascunzi, va fi scoasă din '
            'Favorite și nu va mai apărea în listele de stații, nici în '
            '$car.\n\n'
            'O poți readuce oricând din Setări → Stații ascunse.',
          ),
          findsOneWidget,
        );
        expect(find.text('Anulează'), findsOneWidget);
      },
    );
    expect(confirmed, isTrue);
  },
      variant: const TargetPlatformVariant(
        {TargetPlatform.iOS, TargetPlatform.android},
      ));

  testWidgets('the desktop\'s dialog uses the same wording, without a car',
      (tester) async {
    final confirmed = await open(
      tester,
      confirm: confirmDesktopHide,
      theme: desktopTheme,
      answer: HideFavoriteWording.cancelLabel,
      check: () {
        expect(find.text(HideFavoriteWording.title(station)), findsOneWidget);
        expect(find.text(HideFavoriteWording.message()), findsOneWidget);
        expect(find.textContaining('nici în'), findsNothing);
      },
    );
    expect(confirmed, isFalse);
  });

  testWidgets('the desktop\'s "Ascunde" is filled with the app\'s error red',
      (tester) async {
    final confirmed = await open(
      tester,
      confirm: confirmDesktopHide,
      theme: desktopTheme,
      answer: HideFavoriteWording.hideLabel,
      check: () {
        final hide = tester.widget<FilledButton>(find.widgetWithText(
          FilledButton,
          HideFavoriteWording.hideLabel,
        ));
        expect(
          hide.style?.backgroundColor?.resolve(const <WidgetState>{}),
          AppColors.error,
        );
      },
    );
    expect(confirmed, isTrue);
  });
}
