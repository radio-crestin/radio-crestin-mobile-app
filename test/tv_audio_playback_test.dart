/// Regression tests for the Android TV audio playback path.
///
/// These don't actually play audio (that requires a device), but they pin
/// down the contract that surrounds playback so the things we verified
/// manually on the emulator don't regress silently:
///
///   1. The Android network security config allows cleartext HTTP — the
///      production Icecast/Shoutcast stream hosts are not all HTTPS.
///   2. The stream-list shape produced by the GraphQL → audio handler
///      bridge keeps the order/type contract that ExoPlayer expects.
///   3. Station factory wires up valid stream URIs end-to-end.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/utils.dart';

import 'helpers/station_factory.dart';

Query$GetStations$stations$station_streams _stream(
    int order, String url, String type) {
  return Query$GetStations$stations$station_streams(
    order: order,
    type: type,
    stream_url: url,
  );
}

void main() {
  group('Android cleartext HTTP — network_security_config', () {
    final configFile = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    );

    test('config file exists', () {
      expect(configFile.existsSync(), isTrue,
          reason: 'Manifest references this file via networkSecurityConfig');
    });

    test('cleartext is allowed (matches iOS NSAllowsArbitraryLoads=true)', () {
      final xml = configFile.readAsStringSync();
      // The fix replaced the 127.0.0.1-only domain-config with a base-config
      // that allows cleartext globally. ExoPlayer otherwise rejects http://
      // streams with CleartextNotPermittedException on API 28+.
      expect(xml, contains('cleartextTrafficPermitted="true"'),
          reason: 'Cleartext must be permitted somewhere in the config');
      expect(xml, contains('<base-config'),
          reason: 'A global base-config is required so the allow applies to '
              'every host, not just one domain');
    });
  });

  group('Stream list shape (audio handler ↔ player bridge)', () {
    test('getStationStreamObjects preserves API order', () {
      final station = StationFactory.createRawStation(
        id: 1,
        slug: 'test-station',
        title: 'Test',
        stationStreams: [
          // Intentionally out of order; the helper must sort by `order`.
          _stream(2, 'https://stream.example.com/test/2.mp3', 'mp3'),
          _stream(0, 'https://stream.example.com/test/0.m3u8', 'HLS'),
          _stream(1, 'http://stream.example.com/test/1.mp3', 'mp3'),
        ],
      );

      final out = Utils.getStationStreamObjects(station);

      expect(out, hasLength(3));
      expect(out[0]['url'], 'https://stream.example.com/test/0.m3u8');
      expect(out[0]['type'], 'HLS');
      expect(out[1]['url'], 'http://stream.example.com/test/1.mp3');
      expect(out[1]['type'], 'mp3');
      expect(out[2]['url'], 'https://stream.example.com/test/2.mp3');
      expect(out[2]['type'], 'mp3');
    });

    test('cleartext (http://) entries survive the bridge unmodified', () {
      // The audio handler retries through this list on Source error. A
      // production radio stream may only have an HTTP URL — the bridge
      // must not strip or rewrite it; the Android manifest now allows it.
      final station = StationFactory.createRawStation(
        id: 1,
        slug: 'http-only',
        title: 'HTTP only',
        stationStreams: [
          _stream(0, 'http://94.130.106.91/stream', 'mp3'),
        ],
      );

      final out = Utils.getStationStreamObjects(station);

      expect(out.single['url'], startsWith('http://'));
    });

    test('returns empty list when the station has no streams', () {
      final station = StationFactory.createRawStation(
        id: 1,
        slug: 'empty',
        title: 'Empty',
        stationStreams: <Query$GetStations$stations$station_streams>[],
      );
      expect(Utils.getStationStreamObjects(station), isEmpty);
    });
  });

  group('Station factory wires URIs end-to-end', () {
    test('default factory station produces a parseable stream URL', () {
      final station = StationFactory.createStation(
        id: 1,
        slug: 'radio-emanuel',
        title: 'Radio Emanuel',
      );
      final streams = Utils.getStationStreamObjects(station.rawStationData);
      expect(streams, isNotEmpty);
      // ExoPlayer hands the URL to Uri.parse — anything malformed fails fast.
      final uri = Uri.parse(streams.first['url']!);
      expect(uri.host, isNotEmpty);
      expect(uri.scheme, isIn(['http', 'https']));
    });
  });
}

