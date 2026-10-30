import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radio_crestin/services/mac_app_store_updates.dart';
import 'package:radio_crestin/tv/desktop/desktop_update_dialog.dart';
import 'package:radio_crestin/tv/tv_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _lookup(List<Map<String, Object?>> results) =>
    json.encode({'resultCount': results.length, 'results': results});

void main() {
  group('parseLookup', () {
    test('takes the Mac release', () {
      final release = MacAppStoreUpdates.parseLookup(_lookup([
        {'kind': 'software', 'version': '1.7.0'},
        {
          'kind': 'mac-software',
          'version': '1.6.0',
          'releaseNotes': '  Mai rapid.  ',
        },
      ]));
      expect(release?.version, '1.6.0');
      expect(release?.releaseNotes, 'Mai rapid.');
    });

    test('ignores an iPhone-only listing, as the store has it today', () {
      expect(
        MacAppStoreUpdates.parseLookup(_lookup([
          {'kind': 'software', 'version': '1.5.1'},
        ])),
        isNull,
      );
    });

    test('ignores what is not the store\'s answer', () {
      expect(MacAppStoreUpdates.parseLookup('nu e json'), isNull);
      expect(MacAppStoreUpdates.parseLookup('{"results": 3}'), isNull);
      expect(MacAppStoreUpdates.parseLookup(_lookup([])), isNull);
    });
  });

  test('isNewer compares versions part by part, as numbers', () {
    expect(MacAppStoreUpdates.isNewer('1.6.0', '1.5.1'), isTrue);
    expect(MacAppStoreUpdates.isNewer('1.10.0', '1.9.9'), isTrue);
    expect(MacAppStoreUpdates.isNewer('2.0', '1.9.9'), isTrue);
    expect(MacAppStoreUpdates.isNewer('1.5.1', '1.5.1'), isFalse);
    expect(MacAppStoreUpdates.isNewer('1.5.0', '1.5.1'), isFalse);
    expect(MacAppStoreUpdates.isNewer('1.5.1', '1.5.1+98'), isFalse);
  });

  group('check', () {
    late SharedPreferences prefs;
    late DateTime now;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      now = DateTime(2026, 11, 1, 10);
    });

    MacAppStoreUpdates updates(String body, {int status = 200}) =>
        MacAppStoreUpdates(
          prefs: prefs,
          currentVersion: '1.5.1',
          client: MockClient((request) async {
            expect(request.url, MacAppStoreUpdates.lookupUri);
            return http.Response(body, status);
          }),
          now: () => now,
        );

    final newer = _lookup([
      {'kind': 'mac-software', 'version': '1.6.0'},
    ]);

    test('offers a newer Mac release', () async {
      expect((await updates(newer).check())?.version, '1.6.0');
    });

    test('offers nothing for the same version or a failed lookup', () async {
      expect(
        await updates(_lookup([
          {'kind': 'mac-software', 'version': '1.5.1'},
        ])).check(),
        isNull,
      );
      expect(await updates(newer, status: 503).check(), isNull);
    });

    test('"Mai târziu" puts the version off for a few days', () async {
      final store = updates(newer);
      await store.postpone((await store.check())!);
      expect(await store.check(), isNull);

      now = now.add(MacAppStoreUpdates.snooze + const Duration(minutes: 1));
      expect((await store.check())?.version, '1.6.0');
    });

    test('a later version is offered at once, put off or not', () async {
      final store = updates(newer);
      await store.postpone((await store.check())!);
      final later = updates(_lookup([
        {'kind': 'mac-software', 'version': '1.6.1'},
      ]));
      expect((await later.check())?.version, '1.6.1');
    });
  });

  group('the dialog', () {
    Future<bool?> open(WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        theme: desktopTheme,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDesktopUpdateDialog(
              context,
              release: const MacAppStoreRelease(
                version: '1.6.0',
                releaseNotes: 'Pornire mai rapidă',
              ),
              currentVersion: '1.5.1',
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('names both versions and what\'s new', (tester) async {
      await open(tester);
      expect(find.text(DesktopUpdateDialog.title), findsOneWidget);
      expect(find.textContaining('1.6.0'), findsOneWidget);
      expect(find.textContaining('1.5.1'), findsOneWidget);
      expect(find.text('Pornire mai rapidă'), findsOneWidget);
    });

    testWidgets('"Actualizează" chooses the update', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDesktopUpdateDialog(
              context,
              release: const MacAppStoreRelease(version: '1.6.0'),
              currentVersion: '1.5.1',
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(DesktopUpdateDialog.updateLabel));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(DesktopUpdateDialog.laterLabel));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });
}
