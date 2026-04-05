import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_crestin/seek_mode_manager.dart';

void main() {
  group('SeekModeManager', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SeekModeManager.changeSeekMode(SeekMode.twoMinutes);
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
      test('loads saved mode from prefs', () async {
        SharedPreferences.setMockInitialValues({
          'seek_mode': 'SeekMode.fiveMinutes',
        });
        final prefs = await SharedPreferences.getInstance();

        SeekModeManager.initializeFromPrefs(prefs);
        expect(SeekModeManager.seekMode.value, SeekMode.fiveMinutes);
      });

      test('defaults to twoMinutes when nothing saved', () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        SeekModeManager.initializeFromPrefs(prefs);
        expect(SeekModeManager.seekMode.value, SeekMode.twoMinutes);
      });
    });
  });
}
