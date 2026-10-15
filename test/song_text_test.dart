import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/components/FullAudioPlayer.dart';

void main() {
  group('songClipboardText', () {
    test('puts the title first, then the artist', () {
      expect(
        songClipboardText(title: 'I Can Only Imagine', artist: 'MercyMe'),
        'I Can Only Imagine - MercyMe',
      );
    });

    test('is the title alone when the station named no artist', () {
      expect(songClipboardText(title: 'Spot', artist: ''), 'Spot');
    });

    test('is the artist alone when the station named no title', () {
      expect(songClipboardText(title: '', artist: 'MercyMe'), 'MercyMe');
    });
  });

  group('songSearchQuery', () {
    test('puts the artist first, then the title', () {
      expect(
        songSearchQuery(title: 'I Can Only Imagine', artist: 'MercyMe'),
        'MercyMe - I Can Only Imagine',
      );
    });

    test('has no dangling separator when a part is missing', () {
      expect(songSearchQuery(title: 'Spot', artist: ''), 'Spot');
      expect(songSearchQuery(title: '', artist: 'MercyMe'), 'MercyMe');
    });
  });
}
