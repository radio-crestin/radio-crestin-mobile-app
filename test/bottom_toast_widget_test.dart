import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/bottom_toast.dart';

void main() {
  // HapticFeedback.lightImpact() goes through SystemChannels.platform —
  // intercept it so the tests stay quiet and deterministic.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<OverlayEntry> showHostedToast(
    WidgetTester tester, {
    required String title,
    required String message,
    Duration duration = const Duration(milliseconds: 200),
    bool isError = false,
    VoidCallback? onDismissed,
  }) async {
    OverlayEntry? entry;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) {
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  entry = showBottomToast(
                    context,
                    title: title,
                    message: message,
                    duration: duration,
                    isError: isError,
                    onDismissed: onDismissed,
                  );
                },
                child: const Text('show'),
              ),
            ),
          );
        }),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump(); // entry inserted
    expect(entry, isNotNull);
    return entry!;
  }

  testWidgets('renders title and message in an OverlayEntry', (tester) async {
    await showHostedToast(
      tester,
      title: 'Hello',
      message: 'World',
      duration: const Duration(seconds: 5),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('World'), findsOneWidget);
  });

  testWidgets('auto-dismisses and invokes onDismissed', (tester) async {
    var dismissed = false;
    await showHostedToast(
      tester,
      title: 'auto',
      message: 'gone',
      duration: const Duration(milliseconds: 200),
      onDismissed: () => dismissed = true,
    );

    // Slide-in (350ms) + duration (200ms) + slide-out (250ms) = ~800ms.
    await tester.pump(const Duration(milliseconds: 400)); // slide in
    await tester.pump(const Duration(milliseconds: 250)); // duration elapses
    await tester.pump(const Duration(milliseconds: 300)); // slide out
    await tester.pumpAndSettle();

    expect(dismissed, true);
    expect(find.text('auto'), findsNothing);
  });

  testWidgets('removeBottomToast is a no-op for null', (tester) async {
    expect(() => removeBottomToast(null), returnsNormally);
  });

  testWidgets('removeBottomToast tolerates already-removed entry',
      (tester) async {
    final entry = await showHostedToast(
      tester,
      title: 't',
      message: 'm',
      duration: const Duration(milliseconds: 50),
    );
    await tester.pumpAndSettle();
    // entry is already auto-removed by now — should not throw.
    expect(() => removeBottomToast(entry), returnsNormally);
  });

  testWidgets('error variant uses 5s duration override', (tester) async {
    await showHostedToast(
      tester,
      title: 'oops',
      message: 'fail',
      isError: true,
      // Caller passes a short duration but isError forces 5s.
      duration: const Duration(milliseconds: 1),
    );
    await tester.pump(const Duration(milliseconds: 400)); // slide in
    // Still visible after a second — confirms isError ignored caller's 1ms.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('oops'), findsOneWidget);
    expect(find.text('fail'), findsOneWidget);

    // Clean up — let it dismiss naturally.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
