import 'dart:io';

import 'package:extended_image/extended_image.dart'
    show cacheImageFolderName, keyToMd5;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:radio_crestin/constants.dart';
import 'package:radio_crestin/services/network_service.dart';
import 'package:radio_crestin/utils.dart';

import 'helpers/station_factory.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempPath);
  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  late Directory tempDir;
  late Directory cacheDir;
  final now = DateTime.now();
  final eightDaysAgo = now.subtract(const Duration(days: 8));

  File writeCacheFile(String name, {DateTime? modified}) {
    final file = File('${cacheDir.path}/$name')..writeAsBytesSync([1, 2, 3]);
    if (modified != null) file.setLastModifiedSync(modified);
    return file;
  }

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Utils.getStationThumbnailUrl reads NetworkService.instance.
    NetworkService();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('img_prune_');
    cacheDir = Directory('${tempDir.path}/$cacheImageFolderName')
      ..createSync();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('Utils.deleteStaleCacheFiles', () {
    test('deletes old files, keeps fresh and kept ones', () {
      final old = writeCacheFile('old', modified: eightDaysAgo);
      final fresh = writeCacheFile('fresh');
      final kept = writeCacheFile('logo', modified: eightDaysAgo);

      final deleted = Utils.deleteStaleCacheFiles(
        cacheDir.path,
        now.subtract(const Duration(days: 7)),
        {'logo'},
      );

      expect(deleted, 1);
      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(kept.existsSync(), isTrue);
    });

    test('leaves sub-directories alone', () {
      final sub = Directory('${cacheDir.path}/sub')..createSync();

      Utils.deleteStaleCacheFiles(
        cacheDir.path,
        now.add(const Duration(days: 1)),
        const {},
      );

      expect(sub.existsSync(), isTrue);
    });

    test('missing directory is a no-op', () {
      expect(
        Utils.deleteStaleCacheFiles('${tempDir.path}/missing', now, const {}),
        0,
      );
    });
  });

  group('Utils.pruneImageDiskCache', () {
    test('prunes old song art in the extended_image folder, keeps logos',
        () async {
      const logoUrl = 'https://example.com/logo.png';
      const songUrl = 'https://example.com/song.png';
      final logo = writeCacheFile(keyToMd5(logoUrl), modified: eightDaysAgo);
      final song = writeCacheFile(keyToMd5(songUrl), modified: eightDaysAgo);

      await Utils.pruneImageDiskCache(keepUrls: const [logoUrl]);

      expect(logo.existsSync(), isTrue);
      expect(song.existsSync(), isFalse);
    });
  });

  group('Utils.stationLogoUrls', () {
    tearDown(() {
      CONSTANTS.IMAGE_PROXY_PREFIX = '';
    });

    test('covers the URLs a station logo is displayed and cached under', () {
      CONSTANTS.IMAGE_PROXY_PREFIX = 'https://proxy.example.com/';
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        thumbnailUrl: 'https://example.com/thumb.png',
        nowPlaying: null,
      );

      final urls = Utils.stationLogoUrls([raw]);

      // Primary URL (what displayImage loads) and fallback URL.
      expect(urls, contains(Utils.getStationThumbnailUrl(raw)));
      expect(urls, contains('https://example.com/thumb.png'));
    });

    test('without a proxy the logo URL is used as-is', () {
      final raw = StationFactory.createRawStation(
        id: 1,
        slug: 'test',
        title: 'Test',
        thumbnailUrl: 'https://example.com/thumb.png',
        nowPlaying: null,
      );

      expect(Utils.stationLogoUrls([raw]), {'https://example.com/thumb.png'});
    });
  });
}
