import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/android_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('resolveUseSkia', () {
    test('the Settings choice wins over the flag', () {
      for (final flagOn in [true, false]) {
        expect(
          AndroidRenderer.resolveUseSkia(
              choice: RendererChoice.skia, flagOn: flagOn),
          isTrue,
        );
        expect(
          AndroidRenderer.resolveUseSkia(
              choice: RendererChoice.impeller, flagOn: flagOn),
          isFalse,
        );
      }
    });

    test('on automatic the flag decides', () {
      expect(
        AndroidRenderer.resolveUseSkia(
            choice: RendererChoice.automatic, flagOn: true),
        isTrue,
      );
      expect(
        AndroidRenderer.resolveUseSkia(
            choice: RendererChoice.automatic, flagOn: false),
        isFalse,
      );
    });
  });

  group('AndroidRenderer', () {
    Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    AndroidRenderer renderer({bool? flag, bool supported = true}) =>
        AndroidRenderer(supported: supported, readFlag: () async => flag);

    test('a fresh install keeps Impeller and asks for nothing', () async {
      final prefs = await prefsWith({});
      final subject = renderer();

      await subject.loadCache(prefs);

      expect(subject.choice, RendererChoice.automatic);
      expect(subject.launchUsesSkia, isFalse);
      expect(subject.nextLaunchUsesSkia, isFalse);
    });

    test('the flag turned on stores Skia for the next launch', () async {
      final prefs = await prefsWith({});
      final subject = renderer(flag: true);
      await subject.loadCache(prefs);

      await subject.onFlagsLoaded();

      expect(prefs.getBool(AndroidRenderer.useSkiaKey), isTrue);
      expect(subject.launchUsesSkia, isFalse,
          reason: 'this launch already started with Impeller');
    });

    test('a missing flag stores Impeller', () async {
      final prefs = await prefsWith({
        AndroidRenderer.useSkiaKey: true,
        'android_stable_renderer_flag': true,
      });
      final subject = renderer(flag: null);
      await subject.loadCache(prefs);

      await subject.onFlagsLoaded();

      expect(prefs.getBool(AndroidRenderer.useSkiaKey), isFalse);
    });

    test('the cached flag applies until the live one loads', () async {
      final prefs = await prefsWith({
        AndroidRenderer.useSkiaKey: true,
        'android_stable_renderer_flag': true,
      });
      final subject = renderer();
      await subject.loadCache(prefs);

      expect(subject.launchUsesSkia, isTrue);
      expect(subject.nextLaunchUsesSkia, isTrue);

      await subject.setChoice(RendererChoice.automatic);
      expect(prefs.getBool(AndroidRenderer.useSkiaKey), isTrue);
    });

    test('a forced choice outlasts the flag', () async {
      final prefs = await prefsWith({});
      final subject = renderer(flag: true);
      await subject.loadCache(prefs);

      await subject.setChoice(RendererChoice.impeller);
      await subject.onFlagsLoaded();
      expect(prefs.getBool(AndroidRenderer.useSkiaKey), isFalse);

      final relaunched = renderer(flag: false);
      await relaunched.loadCache(prefs);
      expect(relaunched.choice, RendererChoice.impeller);

      await relaunched.setChoice(RendererChoice.skia);
      await relaunched.onFlagsLoaded();
      expect(prefs.getBool(AndroidRenderer.useSkiaKey), isTrue);
    });

    test('a failed flag read keeps the stored choice', () async {
      final prefs = await prefsWith({AndroidRenderer.useSkiaKey: true});
      final subject = AndroidRenderer(
        supported: true,
        readFlag: () async => throw Exception('offline'),
      );
      await subject.loadCache(prefs);

      await subject.onFlagsLoaded();

      expect(prefs.getBool(AndroidRenderer.useSkiaKey), isTrue);
    });

    test('does nothing off Android', () async {
      final prefs = await prefsWith({});
      final subject = renderer(flag: true, supported: false);
      await subject.loadCache(prefs);

      await subject.onFlagsLoaded();
      await subject.setChoice(RendererChoice.skia);

      expect(prefs.getKeys(), isEmpty);
    });
  });
}
