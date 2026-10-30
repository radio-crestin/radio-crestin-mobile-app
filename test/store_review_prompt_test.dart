import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/globals.dart';
import 'package:radio_crestin/services/store_review_prompt.dart';
import 'package:radio_crestin/utils.dart';

/// Tests for how each device asks for a store rating, and for the macOS
/// path: the system's prompt instead of the app's dialog.
void main() {
  group('StoreReviewPrompt.resolve', () {
    StoreReviewPrompt resolve({
      bool androidTv = false,
      bool desktop = false,
      bool macOS = false,
    }) =>
        StoreReviewPrompt.resolve(
          androidTv: androidTv,
          desktop: desktop,
          macOS: macOS,
        );

    test('phones and tablets show the app dialog', () {
      expect(resolve(), StoreReviewPrompt.dialog);
    });

    test('a Mac asks for the system prompt', () {
      expect(resolve(desktop: true, macOS: true), StoreReviewPrompt.system);
    });

    test('Windows and Linux never ask', () {
      expect(resolve(desktop: true), StoreReviewPrompt.none);
    });

    test('Android TV never asks', () {
      expect(resolve(androidTv: true), StoreReviewPrompt.none);
    });
  });

  group('the review prompt on macOS', () {
    const channel = MethodChannel('dev.britannio.in_app_review');
    const dialogTitle = 'Lasă-ne un review de 5 stele';
    late List<String> calls;

    setUp(() {
      calls = [];
      Utils.debugReviewPrompt = StoreReviewPrompt.system;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'isAvailable' ? true : null;
      });
    });

    tearDown(() {
      Utils.debugReviewPrompt = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    void seedActions(int actionsMade) {
      SharedPreferences.setMockInitialValues({
        '_reviewStatus': json.encode({
          'actions_made': actionsMade,
          'review_completed': false,
        }),
      });
    }

    Future<void> pumpHome(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
        );

    Future<Map<String, dynamic>> reviewStatus() async {
      final prefs = await SharedPreferences.getInstance();
      return json.decode(prefs.getString('_reviewStatus')!)
          as Map<String, dynamic>;
    }

    testWidgets('asks the system at a threshold, without the app dialog',
        (tester) async {
      seedActions(19);
      await pumpHome(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await Utils.incrementActionsMade();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(calls, ['requestReview']);
      expect(find.text(dialogTitle), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('rating_dialog_shown_at_20'), true);
      // The app can't know whether the listener rated it.
      expect((await reviewStatus())['review_completed'], false);
    });

    testWidgets('waits while the window is hidden', (tester) async {
      seedActions(19);
      await pumpHome(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      await Utils.incrementActionsMade();
      await tester.pump(const Duration(seconds: 3));

      expect(calls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('rating_dialog_shown_at_20'), isNull);

      // The next action with the window in front asks.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Utils.incrementActionsMade();
      await tester.pump(const Duration(seconds: 3));

      expect(calls, ['requestReview']);
      expect(prefs.getBool('rating_dialog_shown_at_20'), true);
    });

    testWidgets('asks at most once per app version', (tester) async {
      addTearDown(() => appVersion = '');
      appVersion = '1.5.1';
      seedActions(19);
      await pumpHome(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await Utils.incrementActionsMade();
      await tester.pump(const Duration(seconds: 3));
      expect(calls, ['requestReview']);

      // The next threshold in the same version marks itself, asks nothing.
      final prefs = await SharedPreferences.getInstance();
      final status = await reviewStatus();
      status['actions_made'] = 79;
      await prefs.setString('_reviewStatus', json.encode(status));
      await Utils.incrementActionsMade();
      await tester.pump(const Duration(seconds: 3));
      expect(calls, ['requestReview']);
      expect(prefs.getBool('rating_dialog_shown_at_80'), true);

      // A new version asks again at its next threshold.
      appVersion = '1.6.0';
      status['actions_made'] = 199;
      await prefs.setString('_reviewStatus', json.encode(status));
      await Utils.incrementActionsMade();
      await tester.pump(const Duration(seconds: 3));
      expect(calls, ['requestReview', 'requestReview']);
    });

    testWidgets('asks nothing between thresholds', (tester) async {
      seedActions(5);
      await pumpHome(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await Utils.incrementActionsMade();
      await tester.pump(const Duration(seconds: 3));

      expect(calls, isEmpty);
      expect((await reviewStatus())['actions_made'], 6);
    });
  });

  test('devices without a store review do not count actions', () async {
    Utils.debugReviewPrompt = StoreReviewPrompt.none;
    addTearDown(() => Utils.debugReviewPrompt = null);
    SharedPreferences.setMockInitialValues({
      '_reviewStatus': json.encode({'actions_made': 5}),
    });

    await Utils.incrementActionsMade();

    final prefs = await SharedPreferences.getInstance();
    final status = json.decode(prefs.getString('_reviewStatus')!);
    expect(status['actions_made'], 5);
  });
}
