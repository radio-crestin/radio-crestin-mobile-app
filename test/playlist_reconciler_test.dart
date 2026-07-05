import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/playlist_reconciler.dart';
import 'package:radio_crestin/types/playlist_item.dart';

PlaylistItem item(int id,
    {int? order, PlaylistItemType type = PlaylistItemType.audio}) {
  return PlaylistItem(
    id: id,
    order: order ?? id,
    type: type,
    url: 'https://cdn/$id.mp3',
    title: 'Item $id',
  );
}

List<PlaylistItem> list(List<int> ids) => ids.map((i) => item(i)).toList();

void main() {
  group('PlaylistReconciler.reconcile', () {
    test('appends new items, keeps current playing (no restart)', () {
      final result = PlaylistReconciler.reconcile(
        current: list([1, 2, 3]),
        currentIndex: 1, // playing id 2
        incoming: list([1, 2, 3, 4]),
      );
      expect(result.items.map((e) => e.id), [1, 2, 3, 4]);
      expect(result.currentIndex, 1);
      expect(result.currentItemRemoved, isFalse);
      expect(result.shouldStop, isFalse);
    });

    test('drops a removed non-current item, current index follows', () {
      final result = PlaylistReconciler.reconcile(
        current: list([1, 2, 3]),
        currentIndex: 2, // playing id 3
        incoming: list([1, 3]), // id 2 removed
      );
      expect(result.items.map((e) => e.id), [1, 3]);
      expect(result.currentIndex, 1); // id 3 is now at index 1
      expect(result.currentItemRemoved, isFalse);
      expect(result.shouldStop, isFalse);
    });

    test('reordering keeps the current item without restarting', () {
      final result = PlaylistReconciler.reconcile(
        current: list([1, 2, 3]),
        currentIndex: 0, // playing id 1
        incoming: list([3, 2, 1]),
      );
      expect(result.currentIndex, 2); // id 1 moved to the end
      expect(result.currentItemRemoved, isFalse);
    });

    test('current removed → advances to next surviving item', () {
      final result = PlaylistReconciler.reconcile(
        current: list([1, 2, 3]),
        currentIndex: 1, // playing id 2
        incoming: list([1, 3]), // id 2 removed
      );
      expect(result.currentItemRemoved, isTrue);
      expect(result.shouldStop, isFalse);
      expect(result.items[result.currentIndex].id, 3);
    });

    test('current removed → skips gaps to first forward survivor', () {
      final result = PlaylistReconciler.reconcile(
        current: list([1, 2, 3, 4]),
        currentIndex: 0, // playing id 1
        incoming: list([3, 4]), // ids 1 and 2 removed
      );
      expect(result.currentItemRemoved, isTrue);
      expect(result.items[result.currentIndex].id, 3);
    });

    test('current removed with no forward survivor → stop', () {
      final result = PlaylistReconciler.reconcile(
        current: list([1, 2, 3]),
        currentIndex: 2, // playing id 3 (last)
        incoming: list([1]), // only id 1 remains (before current)
      );
      expect(result.currentItemRemoved, isTrue);
      expect(result.shouldStop, isTrue);
      expect(result.currentIndex, -1);
    });

    test('empty incoming stops playback', () {
      final result = PlaylistReconciler.reconcile(
        current: list([1, 2, 3]),
        currentIndex: 1,
        incoming: const [],
      );
      expect(result.items, isEmpty);
      expect(result.shouldStop, isTrue);
      expect(result.currentIndex, -1);
      expect(result.currentItemRemoved, isTrue);
    });

    test('nothing playing + non-empty incoming just adopts the list', () {
      final result = PlaylistReconciler.reconcile(
        current: const [],
        currentIndex: -1,
        incoming: list([1, 2]),
      );
      expect(result.items.map((e) => e.id), [1, 2]);
      expect(result.currentIndex, -1);
      expect(result.shouldStop, isFalse);
      expect(result.currentItemRemoved, isFalse);
    });

    test('deduplicates incoming by id, preserving order', () {
      final result = PlaylistReconciler.reconcile(
        current: const [],
        currentIndex: -1,
        incoming: [item(1), item(1), item(2)],
      );
      expect(result.items.map((e) => e.id), [1, 2]);
    });
  });

  group('PlaylistNavigator.nextPlayableIndex', () {
    List<PlaylistItem> mixed() => [
          item(1, type: PlaylistItemType.audio),
          item(2, type: PlaylistItemType.youtube),
          item(3, type: PlaylistItemType.audio),
        ];

    test('next advances by one', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: list([1, 2, 3]),
          fromIndex: 0,
          skipYoutube: false,
          loop: true,
        ),
        1,
      );
    });

    test('loops from last back to first', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: list([1, 2, 3]),
          fromIndex: 2,
          skipYoutube: false,
          loop: true,
        ),
        0,
      );
    });

    test('stops at end when not looping', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: list([1, 2, 3]),
          fromIndex: 2,
          skipYoutube: false,
          loop: false,
        ),
        -1,
      );
    });

    test('previous steps backwards', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: list([1, 2, 3]),
          fromIndex: 2,
          skipYoutube: false,
          loop: true,
          direction: -1,
        ),
        1,
      );
    });

    test('previous wraps to the last item', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: list([1, 2, 3]),
          fromIndex: 0,
          skipYoutube: false,
          loop: true,
          direction: -1,
        ),
        2,
      );
    });

    test('skips youtube items when skipYoutube (car/cast)', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: mixed(),
          fromIndex: 0,
          skipYoutube: true,
          loop: true,
        ),
        2, // skips the youtube item at index 1
      );
    });

    test('plays youtube items when not skipping', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: mixed(),
          fromIndex: 0,
          skipYoutube: false,
          loop: true,
        ),
        1,
      );
    });

    test('skips youtube_playlist items too when skipYoutube (car/cast)', () {
      final items = [
        item(1, type: PlaylistItemType.audio),
        item(2, type: PlaylistItemType.youtubePlaylist),
        item(3, type: PlaylistItemType.audio),
      ];
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: items,
          fromIndex: 0,
          skipYoutube: true,
          loop: true,
        ),
        2, // youtube_playlist at index 1 stepped over
      );
    });

    test('plays youtube_playlist items when not skipping (phone/TV)', () {
      final items = [
        item(1, type: PlaylistItemType.audio),
        item(2, type: PlaylistItemType.youtubePlaylist),
        item(3, type: PlaylistItemType.audio),
      ];
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: items,
          fromIndex: 0,
          skipYoutube: false,
          loop: true,
        ),
        1,
      );
    });

    test('always skips unknown items, even when not skipping youtube', () {
      final items = [
        item(1, type: PlaylistItemType.audio),
        item(2, type: PlaylistItemType.unknown),
        item(3, type: PlaylistItemType.audio),
      ];
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: items,
          fromIndex: 0,
          skipYoutube: false,
          loop: true,
        ),
        2, // unknown at index 1 is never playable
      );
    });

    test('skips a leading unknown when picking the first playable item', () {
      final items = [
        item(1, type: PlaylistItemType.unknown),
        item(2, type: PlaylistItemType.youtube),
        item(3, type: PlaylistItemType.audio),
      ];
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: items,
          fromIndex: -1,
          skipYoutube: false,
          loop: false,
        ),
        1, // unknown skipped, youtube is playable off-car
      );
    });

    test('returns -1 when every item is unknown', () {
      final items = [
        item(1, type: PlaylistItemType.unknown),
        item(2, type: PlaylistItemType.unknown),
      ];
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: items,
          fromIndex: -1,
          skipYoutube: false,
          loop: true,
        ),
        -1,
      );
    });

    test('returns -1 when every item is youtube and skipping (car)', () {
      final items = [
        item(1, type: PlaylistItemType.youtube),
        item(2, type: PlaylistItemType.youtube),
      ];
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: items,
          fromIndex: -1,
          skipYoutube: true,
          loop: true,
        ),
        -1,
      );
    });

    test('fromIndex -1 selects the first playable item', () {
      final items = [
        item(1, type: PlaylistItemType.youtube),
        item(2, type: PlaylistItemType.audio),
      ];
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: items,
          fromIndex: -1,
          skipYoutube: true,
          loop: false,
        ),
        1, // youtube skipped, first playable is index 1
      );
    });

    test('empty list returns -1', () {
      expect(
        PlaylistNavigator.nextPlayableIndex(
          items: const [],
          fromIndex: -1,
          skipYoutube: false,
          loop: true,
        ),
        -1,
      );
    });
  });
}
