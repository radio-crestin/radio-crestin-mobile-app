import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/cast_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the iOS Local Network prompt gate: Cast discovery (and so the
/// prompt) must not start at launch until the user taps the cast button.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final discoveryCalls = <String>[];

  setUp(() {
    discoveryCalls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('google_cast.context'),
      (_) async => true,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('google_cast.discovery_manager'),
      (call) async {
        discoveryCalls.add(call.method);
        return true;
      },
    );
  });

  Future<(CastService, SharedPreferences)> launch({
    required bool deferUntilFirstTap,
    Map<String, Object> stored = const {},
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    final prefs = await SharedPreferences.getInstance();
    final service = CastService(
      prefs: prefs,
      deferDiscoveryUntilFirstTap: deferUntilFirstTap,
    );
    await service.initialize();
    return (service, prefs);
  }

  test('fresh install does not start discovery at launch', () async {
    await launch(deferUntilFirstTap: true);

    expect(discoveryCalls, isEmpty);
  });

  test('first cast button tap starts discovery and remembers it', () async {
    final (service, prefs) = await launch(deferUntilFirstTap: true);

    service.onCastButtonTapped();

    expect(discoveryCalls, ['startDiscovery']);
    expect(prefs.getBool('cast_discovery_unlocked'), isTrue);
  });

  test('later launches start discovery right away', () async {
    await launch(
      deferUntilFirstTap: true,
      stored: {'cast_discovery_unlocked': true},
    );

    expect(discoveryCalls, ['startDiscovery']);
  });

  test('platforms without the prompt start discovery at launch', () async {
    final (_, prefs) = await launch(deferUntilFirstTap: false);

    expect(discoveryCalls, ['startDiscovery']);
    expect(prefs.getBool('cast_discovery_unlocked'), isNull);
  });
}
