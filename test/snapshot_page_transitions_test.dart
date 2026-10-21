import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radio_crestin/theme.dart';

// Tests run as Android, which is where this transition is used.
void main() {
  late GlobalKey<NavigatorState> navigator;

  Future<void> pumpApp(
    WidgetTester tester, {
    PageTransitionsBuilder? builder,
  }) async {
    navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: builder == null
          ? darkTheme
          : darkTheme.copyWith(
              pageTransitionsTheme: PageTransitionsTheme(
                builders: {TargetPlatform.android: builder},
              ),
            ),
      navigatorKey: navigator,
      home: const Scaffold(body: Text('Home')),
    ));
  }

  void pushSettings() => navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Setări')),
      ));

  Iterable<SnapshotWidget> drawnAsImages(WidgetTester tester) => tester
      .widgetList<SnapshotWidget>(find.byType(SnapshotWidget))
      .where((widget) => widget.controller.allowSnapshotting);

  testWidgets('both pages fade as images while a page opens', (tester) async {
    await pumpApp(tester);

    pushSettings();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(drawnAsImages(tester), hasLength(2));

    await tester.pumpAndSettle();
    expect(drawnAsImages(tester), isEmpty);
  });

  testWidgets('both pages fade as images while a page closes',
      (tester) async {
    await pumpApp(tester);
    pushSettings();
    await tester.pumpAndSettle();

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(drawnAsImages(tester), hasLength(2));

    await tester.pumpAndSettle();
    expect(drawnAsImages(tester), isEmpty);
  });

  // The ink of the button that opened the page above outlives the 450 ms
  // transition, and stops while its page is covered.
  testWidgets('a page coming back is drawn once its stopped animations end',
      (tester) async {
    navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: darkTheme,
      navigatorKey: navigator,
      home: Scaffold(body: _OpensSettings(onTap: pushSettings)),
    ));
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    // A while on Settings, with the covered page's ink stopped half-way.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('ink', skipOffstage: false), findsOneWidget);

    bool homeDrawnAsImage() => tester
        .widgetList<SnapshotWidget>(find.ancestor(
          of: find.byType(_OpensSettings),
          matching: find.byType(SnapshotWidget),
        ))
        .any((widget) => widget.controller.allowSnapshotting);

    navigator.currentState!.pop();
    await tester.pump();
    expect(homeDrawnAsImage(), isFalse);
    await tester.pump(const Duration(milliseconds: 16));
    expect(homeDrawnAsImage(), isTrue);
    expect(find.text('ink'), findsNothing);
  });

  testWidgets("the pages move as with Flutter's FadeForwards", (tester) async {
    const steps = [0, 30, 60, 100, 150, 250, 400];

    Future<List<Offset>> positions(PageTransitionsBuilder? builder) async {
      await pumpApp(tester, builder: builder);
      final result = <Offset>[];
      Future<void> sample() async {
        var elapsed = 0;
        await tester.pump();
        for (final step in steps) {
          await tester.pump(Duration(milliseconds: step - elapsed));
          elapsed = step;
          result
            ..add(tester.getTopLeft(find.text('Home')))
            ..add(tester.getTopLeft(find.text('Setări')));
        }
        await tester.pumpAndSettle();
      }

      pushSettings();
      await sample();
      navigator.currentState!.pop();
      await sample();
      return result;
    }

    final framework = await positions(
      FadeForwardsPageTransitionsBuilder(
        backgroundColor: darkTheme.scaffoldBackgroundColor,
      ),
    );
    expect(await positions(null), framework);
  });

  testWidgets('a back gesture follows the predictive back transition',
      (tester) async {
    await pumpApp(tester);
    pushSettings();
    await tester.pumpAndSettle();

    Future<void> backGesture(String method, [Object? arguments]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall(method, arguments)),
          (_) {},
        );

    await backGesture('startBackGesture', {
      'touchOffset': [5.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    await tester.pump();
    expect(
      find.byWidgetPredicate((widget) =>
          '${widget.runtimeType}' ==
          '_PredictiveBackSharedElementPageTransition'),
      findsWidgets,
    );
    expect(drawnAsImages(tester), isEmpty);

    await backGesture('updateBackGestureProgress', {
      'touchOffset': [100.0, 300.0],
      'progress': 0.35,
      'swipeEdge': 0,
    });
    await tester.pumpAndSettle();
    await backGesture('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Setări'), findsNothing);
  });
}

/// Runs a 617 ms animation when tapped, like a button's ink, and opens a
/// page.
class _OpensSettings extends StatefulWidget {
  const _OpensSettings({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_OpensSettings> createState() => _OpensSettingsState();
}

class _OpensSettingsState extends State<_OpensSettings>
    with SingleTickerProviderStateMixin {
  late final _ink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 617),
  )..addListener(() => setState(() {}));

  @override
  void dispose() {
    _ink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          _ink.forward(from: 0);
          widget.onTap();
        },
        child: Text(_ink.isAnimating ? 'ink' : 'Home'),
      );
}
