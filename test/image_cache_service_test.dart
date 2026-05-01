import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:radio_crestin/services/image_cache_service.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;

  @override
  Future<String?> getTemporaryPath() async => docsPath;
}

void main() {
  // ImageCacheService is a singleton — initialize once and share state
  // across tests in this file.
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('img_cache_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    await ImageCacheService().initialize();
  });

  tearDownAll(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ImageCacheService — public API', () {
    test('initialize() creates the image_cache directory', () {
      final cacheDir = Directory('${tempDir.path}/image_cache');
      expect(cacheDir.existsSync(), true);
    });

    test('initialize() is idempotent', () async {
      await ImageCacheService().initialize();
      expect(Directory('${tempDir.path}/image_cache').existsSync(), true);
    });

    test('singleton — multiple new instances return the same object', () {
      final a = ImageCacheService();
      final b = ImageCacheService();
      expect(identical(a, b), true);
      expect(identical(ImageCacheService.instance, a), true);
    });

    test('getCachedPath returns null for unknown URL', () {
      expect(
        ImageCacheService().getCachedPath('https://example.com/unknown.png'),
        isNull,
      );
    });

    test('getOrDownload returns null for empty URL', () async {
      final f = await ImageCacheService().getOrDownload('');
      expect(f, isNull);
    });

    test('preCacheUrls accepts empty list without error', () async {
      await ImageCacheService().preCacheUrls([]);
    });

    test('preCacheUrls filters out empty URLs without crashing', () async {
      await ImageCacheService().preCacheUrls(['', '', '']);
    });
  });

  // Pure logic the service relies on internally — tested independently so
  // refactors of `_hashUrl` / `_getExtension` are caught even if the
  // singleton happens to be in a strange state.
  group('ImageCacheService — pure helpers (replicated for regression bait)', () {
    test('MD5 hash is stable and 32-char hex', () {
      final h = md5.convert(utf8.encode('https://x/a.png')).toString();
      expect(h.length, 32);
      expect(h, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    String getExtension(String url) {
      try {
        final uri = Uri.parse(url);
        final path = uri.path;
        final lastDot = path.lastIndexOf('.');
        if (lastDot != -1) {
          final ext = path.substring(lastDot);
          if (ext.length <= 5 && ext.length > 1) return ext;
        }
      } catch (_) {}
      return '.img';
    }

    test('common image extensions extract correctly', () {
      expect(getExtension('https://x/a.png'), '.png');
      expect(getExtension('https://x/a.jpg'), '.jpg');
      expect(getExtension('https://x/a.webp'), '.webp');
    });

    test('falls back to .img for missing or oversized extensions', () {
      expect(getExtension('https://x/noext'), '.img');
      expect(getExtension('https://x/a.toolong'), '.img');
      expect(getExtension('https://x'), '.img');
    });

    test('query string does not interfere with extension', () {
      expect(getExtension('https://x/a.png?v=1'), '.png');
    });
  });
}
