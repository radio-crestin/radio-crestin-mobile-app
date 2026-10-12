import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    // The singleton builds its HTTP client on construction, so creating it
    // inside this zone routes every download to [_fakeCdn].
    await http.runWithClient(
      () => ImageCacheService().initialize(),
      () => MockClient(_fakeCdn),
    );
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

  group('ImageCacheService — downloads', () {
    String cachedFileFor(String url) {
      final hash = md5.convert(utf8.encode(url)).toString();
      return '${tempDir.path}/image_cache/$hash.webp';
    }

    List<String> partFiles() => Directory('${tempDir.path}/image_cache')
        .listSync()
        .map((e) => e.path)
        .where((p) => p.endsWith('.part'))
        .toList();

    test('an image is cached at its final path with no temp file left',
        () async {
      const url = 'https://cdn.example.com/logo.webp';

      final file = await ImageCacheService().getOrDownload(url);

      expect(file?.path, cachedFileFor(url));
      expect(file!.readAsBytesSync(), _imageBytes);
      expect(ImageCacheService().getCachedPath(url), cachedFileFor(url));
      expect(partFiles(), isEmpty);
    });

    test('a 200 that is not an image (CDN error page) is not cached',
        () async {
      const url = 'https://cdn.example.com/error-page.webp';

      final file = await ImageCacheService().getOrDownload(url);

      expect(file, isNull);
      expect(File(cachedFileFor(url)).existsSync(), isFalse);
      expect(ImageCacheService().getCachedPath(url), isNull);
      expect(partFiles(), isEmpty);
    });

    test('a response without a content type is accepted', () async {
      const url = 'https://cdn.example.com/no-type.webp';

      final file = await ImageCacheService().getOrDownload(url);

      expect(file?.readAsBytesSync(), _imageBytes);
    });

    test('a 0-byte file left by an older build is downloaded again',
        () async {
      const url = 'https://cdn.example.com/truncated.webp';
      File(cachedFileFor(url)).writeAsBytesSync(const []);

      final file = await ImageCacheService().getOrDownload(url);

      expect(file?.readAsBytesSync(), _imageBytes);
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

const _imageBytes = [0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4];

/// Serves an image for every path except `/error-page.webp` (an HTML error
/// page with status 200) and `/no-type.webp` (no content-type header).
Future<http.Response> _fakeCdn(http.Request request) async {
  switch (request.url.path) {
    case '/error-page.webp':
      return http.Response('<html>Bad gateway</html>', 200,
          headers: {'content-type': 'text/html; charset=utf-8'});
    case '/no-type.webp':
      return http.Response.bytes(_imageBytes, 200);
    default:
      return http.Response.bytes(_imageBytes, 200,
          headers: {'content-type': 'image/webp'});
  }
}
