import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/sleep_timer_service.dart';
import 'package:radio_crestin/widgets/sleep_timer_button.dart';
import 'package:radio_crestin/widgets/sleep_timer_sheet.dart';

class _FakeClock {
  DateTime now = DateTime(2026, 10, 12, 23, 0);
}

void main() {
  late _FakeClock clock;
  late SleepTimerService service;
  late int stops;

  setUp(() {
    clock = _FakeClock();
    stops = 0;
    service = SleepTimerService(
      stopPlayback: () async => stops++,
      setVolume: (_) async {},
      now: () => clock.now,
    );
  });

  /// Pumps an app whose only button opens the sheet, on [platform].
  Future<void> pumpHost(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () =>
                    SleepTimerSheet.show(context, service: service),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group('on ${platform.name}', () {
      testWidgets('one tap on a duration starts the timer and closes',
          (tester) async {
        await pumpHost(tester, platform: platform);
        await openSheet(tester);
        expect(find.text('Oprește radioul după'), findsOneWidget);
        expect(find.text('Anulează oprirea'), findsNothing);

        // The circle's ink layer sits above its label, so the tap lands on
        // the button rather than the Text itself.
        await tester.tap(find.text('15'), warnIfMissed: false);
        await tester.pump();

        expect(service.state.value?.duration, const Duration(minutes: 15));
        expect(find.text('pornit'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Anulează oprirea'), findsNothing,
            reason: 'the sheet does not grow right before it closes');

        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('pornit'), findsNothing, reason: 'sheet closed');

        service.cancel();
      });

      testWidgets('switching durations keeps the cancel button in place',
          (tester) async {
        service.start(const Duration(minutes: 30));
        await pumpHost(tester, platform: platform);
        await openSheet(tester);
        expect(find.text('Anulează oprirea'), findsOneWidget);

        await tester.tap(find.text('45'), warnIfMissed: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(service.state.value?.duration, const Duration(minutes: 45));
        expect(find.text('pornit'), findsOneWidget);
        expect(find.text('Anulează oprirea'), findsOneWidget,
            reason: 'the sheet does not shrink right before it closes');

        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('pornit'), findsNothing, reason: 'sheet closed');

        service.cancel();
      });

      testWidgets('cancelling confirms, keeps playing, then closes',
          (tester) async {
        service.start(const Duration(minutes: 30));
        await pumpHost(tester, platform: platform);
        await openSheet(tester);

        expect(find.text('30:00'), findsOneWidget);
        expect(find.text('Se oprește la 23:30'), findsOneWidget);
        final heightBefore =
            tester.getSize(find.byType(SleepTimerSheet)).height;

        await tester.tap(find.text('Anulează oprirea'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(service.state.value, isNull);
        expect(stops, 0);
        expect(find.text('Oprirea a fost anulată'), findsOneWidget);
        expect(
          tester.getSize(find.byType(SleepTimerSheet)).height,
          heightBefore,
          reason: 'the sheet keeps its height while confirming',
        );
        final fade = tester.widget<AnimatedOpacity>(find.ancestor(
          of: find.text('Anulează oprirea'),
          matching: find.byType(AnimatedOpacity),
        ));
        expect(fade.opacity, 0, reason: 'the used button fades out in place');

        await tester.pump(const Duration(milliseconds: 1100));
        await tester.pumpAndSettle();
        expect(find.text('Oprirea a fost anulată'), findsNothing);
      });

      testWidgets('fits a narrow 320pt screen without overflow',
          (tester) async {
        tester.view.physicalSize = const Size(960, 1704);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        service.start(const Duration(minutes: 90));

        await pumpHost(tester, platform: platform);
        await openSheet(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('1,5'), findsOneWidget);
        service.cancel();
        await tester.pumpAndSettle();
      });
    });
  }

  testWidgets('the somn button shows a live countdown while armed',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SleepTimerButton(service: service, onTap: () {}),
        ),
      ),
    );
    expect(find.text('somn'), findsOneWidget);

    service.start(const Duration(minutes: 30));
    await tester.pump();
    expect(find.text('30:00'), findsOneWidget);

    // The countdown ticks a few milliseconds after each whole second.
    const tick = Duration(seconds: 1, milliseconds: 5);
    clock.now = clock.now.add(tick);
    await tester.pump(tick);
    expect(find.text('29:59'), findsOneWidget);

    service.cancel();
    await tester.pumpAndSettle();
    expect(find.text('somn'), findsOneWidget);
  });
}
