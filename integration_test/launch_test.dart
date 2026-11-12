import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness/fake_radio_server.dart';
import 'harness/legacy_graphql_cache.dart';
import 'harness/radio_app.dart';
import 'harness/ui_stalls.dart';

/// What a launch does with what an older version left on the device. Its
/// own file, as the app launches once per process (README.md next to this
/// file).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late FakeRadioServer server;
  setUpAll(() async => server = await FakeRadioServer.start());
  tearDownAll(() => server.close());

  late UiStallMeter stalls;

  e2eTest(
    'an update over a grown GraphQL cache launches without freezing',
    server: () => server,
    beforeLaunch: () async {
      await LegacyGraphqlCacheFile.plant(songs: 150000);
      stalls = UiStallMeter.start();
    },
    (app) async {
      stalls.stop();
      // 1.6.1 parsed the whole file on the UI isolate here: 0.8 s on an
      // Apple silicon emulator in debug, past Android's 5 s ANR limit on a
      // slow phone. Without the file: under 50 ms.
      expect(stalls.longest, lessThan(_longestAcceptableStall),
          reason: 'the UI isolate stalled ${stalls.longest.inMilliseconds} ms '
              'during the launch');
      final cache = await LegacyGraphqlCacheFile.file;
      await app.waitFor(() => !cache.existsSync(),
          reason: 'the old cache file to be deleted');
    },
  );
}

/// Well above the launch's own work, well below 1.6.1's parse.
const _longestAcceptableStall = Duration(milliseconds: 300);
