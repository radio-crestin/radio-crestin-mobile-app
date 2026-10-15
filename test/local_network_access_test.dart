import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/local_network_access.dart';
import 'package:radio_crestin/widgets/cast_button.dart';

/// Covers the iOS Local Network hint: once the user denies the prompt, a
/// new Chromecast scan can't find anything, so the device sheet sends them
/// to Settings instead of offering "Caută din nou".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel('com.radiocrestin.local_network');
  const hint = 'Permite accesul la rețeaua locală';
  const searching = 'Căutăm televizoare și boxe';
  MockStreamHandlerEventSink? native;

  /// Fakes the native browse. Called inside each test body, so a widget
  /// test's fake clock delivers the events.
  void mockNativeBrowse() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          native = events;
        },
        onCancel: (_) {
          native = null;
        },
      ),
    );
  }

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(channel, null);
    native = null;
  });

  test('reports each change once and stops the browse on cancel', () async {
    mockNativeBrowse();
    final seen = <LocalNetworkAccess>[];
    final subscription = LocalNetworkAccessMonitor.watch().listen(seen.add);
    await pumpEventQueue();

    native!
      ..success('denied')
      ..success('denied')
      ..success('granted');
    await pumpEventQueue();
    await subscription.cancel();
    await pumpEventQueue();

    expect(seen, [LocalNetworkAccess.denied, LocalNetworkAccess.granted]);
    expect(native, isNull);
  });

  test('does not start a browse off iOS', () async {
    mockNativeBrowse();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    LocalNetworkAccessMonitor.watch().listen((_) {});
    await pumpEventQueue();

    expect(native, isNull);
  });

  testWidgets('sheet shows the Settings hint only while access is denied',
      (tester) async {
    mockNativeBrowse();
    await tester.pumpWidget(MaterialApp(
      // The test font draws each glyph as wide as it is tall, which would
      // overflow the sheet's header row.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.8)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showCastDevicePicker(context, source: 'test'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(searching), findsOneWidget);
    expect(find.text(hint), findsNothing);

    native!.success('denied');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(hint), findsOneWidget);
    expect(find.text('Deschide Setările'), findsOneWidget);
    expect(find.text(searching), findsNothing);

    // Back from Settings with access allowed: the scan starts over.
    native!.success('granted');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(hint), findsNothing);
    expect(find.text(searching), findsOneWidget);

    // The new scan gets its own 15 seconds: the first scan's countdown,
    // which would end it a second early, no longer counts.
    await tester.pump(const Duration(seconds: 14, milliseconds: 500));
    expect(find.text(searching), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(searching), findsNothing);
    expect(find.text('Nu am găsit niciun dispozitiv'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
