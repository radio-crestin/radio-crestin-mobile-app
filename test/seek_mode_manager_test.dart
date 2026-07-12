import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/seek_mode_manager.dart';

void main() {
  group('SeekModeManager', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
      // Runtime overrides are static & sticky — clear them between tests.
      SeekModeManager.changeCarConnected(false);
      SeekModeManager.changeUnstableConnection(false);
      SeekModeManager.changeAutoSlowConnection(false);
    });

    group('autoSlowConnection override', () {
      test('forces 5-minute offset even in instant mode', () {
        SeekModeManager.changeSeekMode(SeekMode.instant);
        expect(SeekModeManager.currentOffset, Duration.zero);
        SeekModeManager.changeAutoSlowConnection(true);
        expect(SeekModeManager.currentOffset, const Duration(minutes: 5));
      });

      test('forces effectiveSeekMode to fiveMinutes', () {
        SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
        expect(SeekModeManager.effectiveSeekMode, SeekMode.twoMinutes);
        SeekModeManager.changeAutoSlowConnection(true);
        expect(SeekModeManager.effectiveSeekMode, SeekMode.fiveMinutes);
        expect(SeekModeManager.isAutoSlowConnection, isTrue);
      });

      test('clearing it restores the user-selected offset', () {
        SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
        SeekModeManager.changeAutoSlowConnection(true);
        SeekModeManager.changeAutoSlowConnection(false);
        expect(SeekModeManager.currentOffset, const Duration(minutes: 2));
      });

      test('is not persisted to SharedPreferences', () async {
        SeekModeManager.changeAutoSlowConnection(true);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('unstable_connection'), isNull);
      });
    });

    group('currentOffset', () {
      test('returns Duration.zero for instant mode', () {
        SeekModeManager.changeSeekMode(SeekMode.instant);
        expect(SeekModeManager.currentOffset, Duration.zero);
      });

      test('returns 2 minutes for twoMinutes mode', () {
        SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
        expect(SeekModeManager.currentOffset, const Duration(minutes: 2));
      });

      test('returns 5 minutes for fiveMinutes mode', () {
        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);
        expect(SeekModeManager.currentOffset, const Duration(minutes: 5));
      });
    });

    group('saveSeekMode', () {
      test('saves instant mode', () async {
        await SeekModeManager.saveSeekMode(SeekMode.instant);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('seek_mode'), 'SeekMode.instant');
      });

      test('saves twoMinutes mode', () async {
        await SeekModeManager.saveSeekMode(SeekMode.twoMinutes);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('seek_mode'), 'SeekMode.twoMinutes');
      });

      test('saves fiveMinutes mode', () async {
        await SeekModeManager.saveSeekMode(SeekMode.fiveMinutes);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('seek_mode'), 'SeekMode.fiveMinutes');
      });
    });

    group('loadSeekMode', () {
      test('returns twoMinutes as default', () async {
        final mode = await SeekModeManager.loadSeekMode();
        expect(mode, SeekMode.twoMinutes);
      });

      test('loads instant mode', () async {
        SharedPreferences.setMockInitialValues({
          'seek_mode': 'SeekMode.instant',
        });
        final mode = await SeekModeManager.loadSeekMode();
        expect(mode, SeekMode.instant);
      });

      test('loads fiveMinutes mode', () async {
        SharedPreferences.setMockInitialValues({
          'seek_mode': 'SeekMode.fiveMinutes',
        });
        final mode = await SeekModeManager.loadSeekMode();
        expect(mode, SeekMode.fiveMinutes);
      });

      test('returns twoMinutes for unknown value', () async {
        SharedPreferences.setMockInitialValues({
          'seek_mode': 'SeekMode.unknown',
        });
        final mode = await SeekModeManager.loadSeekMode();
        expect(mode, SeekMode.twoMinutes);
      });
    });

    group('changeSeekMode', () {
      test('updates the ValueNotifier', () {
        SeekModeManager.changeSeekMode(SeekMode.instant);
        expect(SeekModeManager.seekMode.value, SeekMode.instant);
      });

      test('notifies listeners', () {
        final modes = <SeekMode>[];
        SeekModeManager.seekMode.addListener(() {
          modes.add(SeekModeManager.seekMode.value);
        });

        SeekModeManager.changeSeekMode(SeekMode.instant);
        SeekModeManager.changeSeekMode(SeekMode.fiveMinutes);

        expect(modes, [SeekMode.instant, SeekMode.fiveMinutes]);
      });
    });

    group('initializeFromPrefs', () {
      // The v2 migration (seek_mode_migrated_v2) performs a one-time hard reset
      // for legacy installs that were stuck at 5 minutes. These steady-state
      // tests set the flag so the migration is already done and saved values
      // are respected; the migration itself is covered separately below.
      test('loads saved mode from prefs (post-migration steady state)', () async {
        SharedPreferences.setMockInitialValues({
          'seek_mode_migrated_v2': true,
          'seek_mode': 'SeekMode.fiveMinutes',
        });
        final prefs = await SharedPreferences.getInstance();

        SeekModeManager.initializeFromPrefs(prefs);
        expect(SeekModeManager.seekMode.value, SeekMode.fiveMinutes);
      });

      test('defaults to twoMinutes when nothing saved', () async {
        SharedPreferences.setMockInitialValues({
          'seek_mode_migrated_v2': true,
        });
        final prefs = await SharedPreferences.getInstance();

        SeekModeManager.initializeFromPrefs(prefs);
        expect(SeekModeManager.seekMode.value, SeekMode.twoMinutes);
      });

      test('v2 migration hard-resets a legacy 5-minute install exactly once',
          () async {
        // Legacy install: stuck on 5 minutes via a sticky seek_mode AND an
        // unstable_connection override, with the v2 flag absent.
        SharedPreferences.setMockInitialValues({
          'seek_mode': 'SeekMode.fiveMinutes',
          'unstable_connection': true,
        });
        final prefs = await SharedPreferences.getInstance();

        SeekModeManager.initializeFromPrefs(prefs);

        // Reset to the documented defaults and the flag is now persisted.
        expect(SeekModeManager.seekMode.value, SeekMode.twoMinutes);
        expect(SeekModeManager.unstableConnection.value, isFalse);
        expect(prefs.getString('seek_mode'), 'SeekMode.twoMinutes');
        expect(prefs.getBool('unstable_connection'), isFalse);
        expect(prefs.getBool('seek_mode_migrated_v2'), isTrue);

        // The reset is one-time: a value the user picks afterwards survives the
        // next initialize (the migration does not run again).
        await prefs.setString('seek_mode', 'SeekMode.fiveMinutes');
        SeekModeManager.initializeFromPrefs(prefs);
        expect(SeekModeManager.seekMode.value, SeekMode.fiveMinutes);
      });
    });
  });
}
