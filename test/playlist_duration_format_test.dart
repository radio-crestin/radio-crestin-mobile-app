/// Unit tests for the playlist VOD scrubber duration formatter.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/widgets/playlist_player_section.dart';

void main() {
  group('formatPlaylistDuration', () {
    test('formats sub-minute durations as m:ss', () {
      expect(formatPlaylistDuration(const Duration(seconds: 5)), '0:05');
      expect(formatPlaylistDuration(const Duration(seconds: 45)), '0:45');
    });

    test('formats minute durations as m:ss', () {
      expect(formatPlaylistDuration(const Duration(minutes: 3, seconds: 7)),
          '3:07');
      expect(
          formatPlaylistDuration(const Duration(minutes: 12, seconds: 0)),
          '12:00');
    });

    test('formats hour-plus durations as h:mm:ss', () {
      expect(
          formatPlaylistDuration(
              const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
      expect(
          formatPlaylistDuration(
              const Duration(hours: 2, minutes: 0, seconds: 9)),
          '2:00:09');
    });

    test('clamps negative durations to zero', () {
      expect(formatPlaylistDuration(const Duration(seconds: -5)), '0:00');
    });

    test('zero is 0:00', () {
      expect(formatPlaylistDuration(Duration.zero), '0:00');
    });
  });
}
