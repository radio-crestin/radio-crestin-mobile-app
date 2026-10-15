import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/services/cast_service.dart';
import 'package:radio_crestin/widgets/cast_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the device sheet's Chromecast card: the scan, the devices it
/// finds, and a scan that finds nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const searching = 'Căutăm televizoare și boxe';
  const nothingFound = 'Nu am găsit niciun dispozitiv';

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      // The test font draws each glyph as wide as it is tall.
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
  }

  GoogleCastDevice device(String id, String name, String model) =>
      GoogleCastDevice(
        deviceID: id,
        friendlyName: name,
        modelName: model,
        statusText: null,
        deviceVersion: '1',
        isOnLocalNetwork: true,
        category: 'cast',
        uniqueID: id,
      );

  testWidgets('a scan that finds nothing says so and can start again',
      (tester) async {
    await openSheet(tester);
    expect(find.text(searching), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(searching), findsNothing);
    expect(find.text(nothingFound), findsOneWidget);

    await tester.tap(find.text('Caută din nou'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(searching), findsOneWidget);
    expect(find.text(nothingFound), findsNothing);

    // Let the new scan's countdown run out before the test ends.
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('found devices replace the scan, each with its own icon',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('google_cast.discovery_manager'),
      (_) async => true,
    );
    SharedPreferences.setMockInitialValues({});
    final service = CastService(
      prefs: await SharedPreferences.getInstance(),
      deferDiscoveryUntilFirstTap: false,
    );
    GetIt.instance.registerSingleton<CastService>(service);
    addTearDown(GetIt.instance.reset);

    await openSheet(tester);
    expect(find.text(searching), findsOneWidget);

    service.devices.add([
      device('tv', 'Televizor sufragerie', 'Google TV'),
      device('box', 'Boxă bucătărie', 'Nest Audio'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(searching), findsNothing);
    expect(find.text('GĂSITE ÎN WI-FI-UL TĂU'), findsOneWidget);
    expect(find.text('Conectează'), findsNWidgets(2));
    Finder iconIn(String row, IconData icon) => find.descendant(
          of: find.widgetWithText(InkWell, row),
          matching: find.byIcon(icon),
        );
    expect(iconIn('Televizor sufragerie', Icons.tv_rounded), findsOneWidget);
    expect(iconIn('Boxă bucătărie', Icons.speaker_rounded), findsOneWidget);

    // Still looking for more; once the scan ends it can be started again.
    expect(find.byTooltip('Caută din nou'), findsNothing);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Caută din nou'), findsOneWidget);
    expect(find.text(nothingFound), findsNothing);
  });
}
