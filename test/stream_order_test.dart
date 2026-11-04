import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/playback_preferences.dart';
import 'package:radio_crestin/services/stream_order.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, String> _stream(String url, String type) =>
    {'url': url, 'type': type};

void main() {
  final hls = _stream('https://a/index.m3u8', 'HLS');
  final proxied = _stream('https://b/stream', 'proxied_stream');
  final direct = _stream('https://c/stream.mp3', 'direct_stream');

  group('orderStreams', () {
    test('keeps the given order when direct streams are not first', () {
      final streams = [hls, proxied, direct];

      expect(orderStreams(streams, directFirst: false), same(streams));
    });

    test('moves direct streams ahead of HLS, each group in its order', () {
      final hls2 = _stream('https://d/index.m3u8', 'HLS');

      final ordered =
          orderStreams([hls, proxied, hls2, direct], directFirst: true);

      expect(ordered, [proxied, direct, hls, hls2]);
    });

    test('a station with HLS only keeps its HLS streams', () {
      expect(orderStreams([hls], directFirst: true), [hls]);
    });

    test('an entry without a type counts as a direct stream', () {
      final bare = {'url': 'https://e/stream'};

      expect(orderStreams<Object>([hls, bare], directFirst: true),
          [bare, hls]);
    });
  });

  group('PlaybackPreferences', () {
    tearDown(() => PlaybackPreferences.changePreferDirectStreams(false));

    test('is off until the user turns it on', () async {
      SharedPreferences.setMockInitialValues({});

      PlaybackPreferences.initializeFromPrefs(
          await SharedPreferences.getInstance());

      expect(PlaybackPreferences.preferDirectStreams.value, isFalse);
    });

    test('reads the stored setting and applies a change at once', () async {
      SharedPreferences.setMockInitialValues(
          {PlaybackPreferences.preferDirectStreamsKey: true});

      PlaybackPreferences.initializeFromPrefs(
          await SharedPreferences.getInstance());
      expect(PlaybackPreferences.directStreamsFirst, isTrue);

      PlaybackPreferences.changePreferDirectStreams(false);
      expect(PlaybackPreferences.preferDirectStreams.value, isFalse);
    });

    test('saves the setting for the next launches', () async {
      SharedPreferences.setMockInitialValues({});

      await PlaybackPreferences.savePreferDirectStreams(true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PlaybackPreferences.preferDirectStreamsKey),
          isTrue);
    });
  });
}
