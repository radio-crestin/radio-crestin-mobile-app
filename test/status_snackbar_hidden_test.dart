import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/appAudioHandler.dart' show ConnectionErrorReason;
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/mini_player_bottom_inset.dart';
import 'package:radio_crestin/widgets/status_snackbar.dart';
import 'package:radio_crestin/widgets/status_snackbar_controller.dart';

import 'helpers/station_factory.dart';

/// The snackbar after a station was hidden from its long-press menu: the
/// station, where to find it again, and "Anulează".
void main() {
  late StatusSnackbarController controller;
  late ValueNotifier<double> panel;
  late ValueNotifier<double> listInset;
  late int undos;
  late int retries;

  final station = StationFactory.createStation(
    id: 7,
    slug: 'rve-sibiu',
    title: 'RVE Sibiu',
    thumbnailUrl: null,
  );

  setUp(() {
    controller = StatusSnackbarController();
    panel = ValueNotifier(0);
    listInset = ValueNotifier(0);
    undos = 0;
    retries = 0;
  });
  tearDown(() {
    controller.dispose();
    panel.dispose();
    listInset.dispose();
  });

  Future<void> pumpOverlay(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: lightTheme,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: StatusSnackbarOverlay(
                controller: controller,
                panelPosition: panel,
                panelTravel: 600,
                dockedBottom: kMiniPlayerCollapsedHeight + 20,
                listInset: listInset,
                listReservedInset: kMiniPlayerCollapsedHeight,
                onRetry: () => retries++,
                onUndo: () => undos++,
              ),
            ),
          ],
        ),
      ),
    ));
  }

  final undo = find.text('Anulează');

  testWidgets('names the station, where it went, and offers an undo',
      (tester) async {
    await pumpOverlay(tester);

    controller.showStationHidden(station);
    await tester.pumpAndSettle();

    expect(find.text('RVE Sibiu'), findsOneWidget);
    expect(find.text('Stație ascunsă. O poți readuce din Setări.'),
        findsOneWidget);
    expect(undo, findsOneWidget);
    expect(find.text('Reîncearcă'), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(undo, findsNothing, reason: 'gone on its own after 6s');
  });

  testWidgets('"Anulează" undoes the hide and goes away', (tester) async {
    await pumpOverlay(tester);
    controller.showStationHidden(station);
    await tester.pumpAndSettle();

    await tester.tap(undo);
    await tester.pumpAndSettle();

    expect(undos, 1);
    expect(retries, 0);
    expect(controller.message, isNull);
    expect(undo, findsNothing);
  });

  testWidgets('a swipe down dismisses it without undoing', (tester) async {
    await pumpOverlay(tester);
    controller.showStationHidden(station);
    await tester.pumpAndSettle();

    await tester.drag(
        find.byKey(StatusSnackbar.cardKey), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(undos, 0);
    expect(controller.message, isNull);
  });

  testWidgets('keeps its undo over the open full player', (tester) async {
    await pumpOverlay(tester);
    controller.showStationHidden(station);
    panel.value = 1;
    await tester.pumpAndSettle();

    expect(find.text('Stație ascunsă. O poți readuce din Setări.'),
        findsOneWidget);
    await tester.tap(undo);
    expect(undos, 1);
  });

  group('another page over it', () {
    NavigatorState navigator(WidgetTester tester) => Navigator.of(tester
        .element(find.byType(StatusSnackbarOverlay, skipOffstage: false)));

    /// A page that covers it at once, without a transition.
    Future<void> openPage(WidgetTester tester) async {
      unawaited(navigator(tester).push(PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => const Scaffold(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      )));
      await tester.pumpAndSettle();
    }

    testWidgets('takes the undo away, also once back', (tester) async {
      await pumpOverlay(tester);
      controller.showStationHidden(station);
      await tester.pumpAndSettle();

      await openPage(tester);
      expect(controller.message, isNull);

      navigator(tester).pop();
      await tester.pump();
      expect(undo, findsNothing,
          reason: 'not drawn again on the way back, to play out its exit');
      expect(undos, 0);
    });

    testWidgets('sliding in takes it away as well, the way Settings opens',
        (tester) async {
      await pumpOverlay(tester);
      controller.showStationHidden(station);
      await tester.pumpAndSettle();

      unawaited(navigator(tester)
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold())));
      await tester.pumpAndSettle();

      expect(controller.message, isNull);

      navigator(tester).pop();
      await tester.pump();
      expect(undo, findsNothing,
          reason: 'not drawn again as the page slides away');
      expect(undos, 0);
    });

    testWidgets('a sheet, which leaves the page in sight, keeps it',
        (tester) async {
      await pumpOverlay(tester);
      controller.showStationHidden(station);
      await tester.pumpAndSettle();

      unawaited(showModalBottomSheet<void>(
        context: tester.element(find.byType(StatusSnackbarOverlay)),
        builder: (_) => const SizedBox(height: 200),
      ));
      await tester.pumpAndSettle();

      expect(controller.message?.kind, StatusKind.stationHidden);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('leaves a station error', (tester) async {
      await pumpOverlay(tester);
      controller.showStationError(
        stationTitle: 'RVE Sibiu',
        reason: ConnectionErrorReason.timeout,
        station: station,
      );
      await tester.pumpAndSettle();

      await openPage(tester);

      expect(controller.message?.kind, StatusKind.stationError);
      // It still goes on its own.
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('scrolling the station list', () {
    late ScrollController scroll;

    setUp(() => scroll = ScrollController());
    tearDown(() => scroll.dispose());

    /// The list under the snackbar, as on Home.
    Future<void> pumpListWithOverlay(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: lightTheme,
        home: Scaffold(
          body: Stack(
            children: [
              StatusSnackbarScrollListener(
                controller: controller,
                child: ListView.builder(
                  controller: scroll,
                  itemExtent: 100,
                  itemCount: 50,
                  itemBuilder: (_, i) => Text('row $i'),
                ),
              ),
              Positioned.fill(
                child: StatusSnackbarOverlay(
                  controller: controller,
                  panelPosition: panel,
                  panelTravel: 600,
                  dockedBottom: kMiniPlayerCollapsedHeight + 20,
                  listInset: listInset,
                  listReservedInset: kMiniPlayerCollapsedHeight,
                  onRetry: () => retries++,
                  onUndo: () => undos++,
                ),
              ),
            ],
          ),
        ),
      ));
    }

    final list = find.byType(ListView);

    testWidgets('down or back up takes the undo away, without undoing',
        (tester) async {
      await pumpListWithOverlay(tester);
      controller.showStationHidden(station);
      await tester.pumpAndSettle();

      await tester.drag(list, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(controller.message, isNull);
      expect(undo, findsNothing);

      controller.showStationHidden(station);
      await tester.pumpAndSettle();
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(controller.message, isNull);
      expect(undos, 0);
    });

    testWidgets('moving on its own leaves the undo', (tester) async {
      await pumpListWithOverlay(tester);
      controller.showStationHidden(station);
      await tester.pumpAndSettle();

      scroll.jumpTo(300);
      unawaited(scroll.animateTo(
        100,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      ));
      await tester.pumpAndSettle();

      expect(controller.message?.kind, StatusKind.stationHidden);
      expect(undo, findsOneWidget);
      // It still goes on its own.
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('leaves a station error, which still asks for an answer',
        (tester) async {
      await pumpListWithOverlay(tester);
      controller.showStationError(
        stationTitle: 'RVE Sibiu',
        reason: ConnectionErrorReason.timeout,
        station: station,
      );
      await tester.pumpAndSettle();

      await tester.drag(list, const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(controller.message?.kind, StatusKind.stationError);
      // It still goes on its own.
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
