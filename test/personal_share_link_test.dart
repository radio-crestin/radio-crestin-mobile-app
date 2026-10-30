import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `ShareService.getPersonalShareLink`, the one fetch behind every share
/// button (the phone's Settings, the desktop's station actions and its
/// now-playing panel).
void main() {
  /// The device ids the share link was asked for.
  late List<Object?> askedFor;

  /// A client whose API answers with a link for the device, or fails when
  /// [offline].
  GraphQLClient client({bool offline = false}) => GraphQLClient(
        cache: GraphQLCache(),
        link: Link.function((request, [forward]) async* {
          askedFor.add(request.variables['anonymous_id']);
          if (offline) throw Exception('offline');
          yield Response(
            data: {
              'get_share_link': {
                'share_link': {'share_id': 'abc', 'visit_count': 3},
              },
            },
            response: const {},
          );
        }),
      );

  Future<void> registerPrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    GetIt.instance.registerSingleton<SharedPreferences>(
      await SharedPreferences.getInstance(),
    );
  }

  setUp(() => askedFor = []);
  tearDown(() => GetIt.instance.reset());

  test('asks for the link of the device id saved at startup', () async {
    await registerPrefs({'device_id': 'device-1'});

    final link = await ShareService(client()).getPersonalShareLink();

    expect(askedFor, ['device-1']);
    expect(link?.shareId, 'abc');
    expect(link?.visitCount, 3);
  });

  test('reads the preferences the app registered', () async {
    await registerPrefs({'device_id': 'device-1'});
    // The plugin's own instance knows another id: the registered one wins.
    SharedPreferences.setMockInitialValues({'device_id': 'other'});

    await ShareService(client()).getPersonalShareLink();

    expect(askedFor, ['device-1']);
  });

  test('falls back to the plugin\'s preferences when none are registered',
      () async {
    SharedPreferences.setMockInitialValues({'device_id': 'device-2'});

    final link = await ShareService(client()).getPersonalShareLink();

    expect(askedFor, ['device-2']);
    expect(link?.shareId, 'abc');
  });

  test('is null, without asking, before the device has an id', () async {
    await registerPrefs({});

    expect(await ShareService(client()).getPersonalShareLink(), isNull);
    expect(askedFor, isEmpty);
  });

  test('is null when the request fails', () async {
    await registerPrefs({'device_id': 'device-1'});

    final link =
        await ShareService(client(offline: true)).getPersonalShareLink();

    expect(link, isNull);
    expect(askedFor, ['device-1']);
  });
}
