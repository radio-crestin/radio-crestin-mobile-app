import 'package:flutter/services.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/car_play_service.dart';
import 'package:radio_crestin/types/Station.dart';

import 'helpers/station_factory.dart';

/// Covers the pure helpers behind the CarPlay / Android Auto platform fixes:
/// empty thumbnails never reach native as an image name, and per-poll
/// subtitle updates only cross the platform channel when something changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CarPlayService.resolveCarImageUrl', () {
    test('null and empty URLs resolve to null (no image)', () {
      var lookups = 0;
      String? cachedPathFor(String _) {
        lookups++;
        return '/cache/img.png';
      }

      expect(CarPlayService.resolveCarImageUrl(null, cachedPathFor), isNull);
      expect(CarPlayService.resolveCarImageUrl('', cachedPathFor), isNull);
      expect(lookups, 0, reason: 'No cache lookup for a missing URL');
    });

    test('cached image resolves to a file:// URI', () {
      final result = CarPlayService.resolveCarImageUrl(
        'https://example.com/thumb.png',
        (_) => '/data/image_cache/abc.png',
      );
      expect(result, 'file:///data/image_cache/abc.png');
    });

    test('uncached image keeps the network URL', () {
      final result = CarPlayService.resolveCarImageUrl(
        'https://example.com/thumb.png',
        (_) => null,
      );
      expect(result, 'https://example.com/thumb.png');
    });
  });

  group('CarPlayService.songHistoryThumbnailSource', () {
    test('prefers the song artwork when present', () {
      expect(
        CarPlayService.songHistoryThumbnailSource(
          'https://example.com/song.png',
          'https://example.com/station.png',
        ),
        'https://example.com/song.png',
      );
    });

    test('falls back to the station logo for a null or empty song image', () {
      for (final song in [null, '']) {
        expect(
          CarPlayService.songHistoryThumbnailSource(
            song,
            'https://example.com/station.png',
          ),
          'https://example.com/station.png',
        );
      }
    });

    test('both empty still resolves to no image', () {
      final source = CarPlayService.songHistoryThumbnailSource('', '');
      expect(CarPlayService.resolveCarImageUrl(source, (_) => null), isNull);
    });
  });

  group('CarPlayService.syncListDetailTexts', () {
    const channel = MethodChannel('com.oguzhnatly.flutter_carplay');
    late List<MethodCall> nativeCalls;
    late Map<String, String> subtitles;
    late Map<String, Station> stationsBySlug;

    setUp(() {
      nativeCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call);
        return false;
      });
      final stations = [
        StationFactory.createStation(id: 1, slug: 'a', title: 'A'),
        StationFactory.createStation(id: 2, slug: 'b', title: 'B'),
      ];
      stationsBySlug = {for (final s in stations) s.slug as String: s};
      subtitles = {'a': 'Song A', 'b': ''};
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    bool sync(
      Map<String, CPListItem> items, {
      bool Function(String slug)? isOnTemplate,
    }) =>
        CarPlayService.syncListDetailTexts(
          items: items,
          stationsBySlug: stationsBySlug,
          subtitleFor: (s) => subtitles[s.slug]!,
          isOnTemplate: isOnTemplate,
        );

    test('unchanged subtitles send nothing to native', () async {
      final items = {
        'a': CPListItem(text: 'A', detailText: 'Song A'),
        // A null detail text counts as the empty subtitle.
        'b': CPListItem(text: 'B'),
      };

      final changed = sync(items);
      await pumpEventQueue();

      expect(changed, isFalse);
      expect(nativeCalls, isEmpty);
    });

    test('a changed on-template row is pushed once', () async {
      final items = {
        'a': CPListItem(text: 'A', detailText: 'Old song'),
        'b': CPListItem(text: 'B'),
      };

      final changed = sync(items);
      await pumpEventQueue();

      expect(changed, isTrue);
      expect(items['a']!.detailText, 'Song A');
      expect(nativeCalls.map((c) => c.method), ['updateListItem']);
    });

    test('an off-template row is stored without a native call', () async {
      final items = {'a': CPListItem(text: 'A', detailText: 'Old song')};

      final changed = sync(items, isOnTemplate: (_) => false);
      await pumpEventQueue();

      expect(changed, isFalse);
      expect(nativeCalls, isEmpty);
      // Carried by toJson with the next section update.
      expect(items['a']!.toJson()['detailText'], 'Song A');
    });

    test('rows for stations missing from the update are left alone', () async {
      final items = {'gone': CPListItem(text: 'Gone', detailText: 'x')};

      final changed = sync(items);
      await pumpEventQueue();

      expect(changed, isFalse);
      expect(items['gone']!.detailText, 'x');
      expect(nativeCalls, isEmpty);
    });
  });
}
