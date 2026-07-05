import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/playlist_reconciler.dart';
import 'package:radio_crestin/types/playlist_item.dart';

/// Direction contract for playlist auto-advance under NEWEST-FIRST serving.
///
/// The backend serves playlist items newest-first (highest order first), so the
/// UI shows the newest item at the TOP (index 0) and older items below. Every
/// error/completion advance path in [PlaylistController] —
/// `notifyYoutubeItemError`, the media_kit video error/complete listeners, the
/// just_audio audio error/complete callbacks, and `_onItemCompleted` — funnels
/// through `_advance(direction: 1)`, i.e. `PlaylistNavigator.nextPlayableIndex(
/// direction: 1, loop: true)`. So the single invariant that pins all of them is:
///
///   "next" == the NEXT ROW DOWN (index + 1), wrapping from the last row (tail,
///   oldest) back to the first row (head, newest).
///
/// These tests pin that invariant at head / middle / tail, across mixed item
/// types, and for the car/cast "skip youtube" and unknown-kind step-overs — the
/// exact shape that regressed when serving flipped to newest-first.
PlaylistItem _item(int id, PlaylistItemType type) => PlaylistItem(
      id: id,
      order: id,
      type: type,
      url: 'https://cdn/$id',
      title: 'Item $id',
    );

/// A newest-first list mirroring the seeded "Media Mix" station as displayed:
/// index 0 = newest (audio), index 3 = oldest (youtube).
List<PlaylistItem> _mediaMixNewestFirst() => [
      _item(24, PlaylistItemType.audio), // 0 — newest, top row
      _item(23, PlaylistItemType.video), // 1
      _item(22, PlaylistItemType.youtubePlaylist), // 2 — "IFrame API Docs"
      _item(21, PlaylistItemType.youtube), // 3 — oldest, bottom row
    ];

int _advance(List<PlaylistItem> items, int fromIndex,
        {bool skipYoutube = false}) =>
    PlaylistNavigator.nextPlayableIndex(
      items: items,
      fromIndex: fromIndex,
      skipYoutube: skipYoutube,
      loop: true,
      direction: 1,
    );

void main() {
  group('auto-advance direction (newest-first) — every failure path', () {
    test('advance always moves to the NEXT ROW DOWN (index + 1)', () {
      final items = _mediaMixNewestFirst();
      expect(_advance(items, 0), 1, reason: 'head → row below');
      expect(_advance(items, 1), 2, reason: 'middle → row below');
      expect(_advance(items, 2), 3, reason: 'middle → row below');
    });

    test('advance from the tail (oldest, bottom) WRAPS to the head (top)', () {
      final items = _mediaMixNewestFirst();
      expect(_advance(items, 3), 0);
    });

    test('the reported case: failing the youtube_playlist (index 2, "IFrame '
        'API Docs") advances DOWN to the youtube item (index 3), never up', () {
      final items = _mediaMixNewestFirst();
      final next = _advance(items, 2);
      expect(next, 3);
      expect(items[next].type, PlaylistItemType.youtube);
      // Explicitly assert it did NOT go the wrong way (up towards newer items).
      expect(next, isNot(1));
      expect(next, isNot(0));
    });

    test('a full cascade of failures walks strictly downward then wraps once',
        () {
      final items = _mediaMixNewestFirst();
      // Start at head, fail each item in turn: 0→1→2→3→(wrap)→0.
      final visited = <int>[0];
      var idx = 0;
      for (var i = 0; i < items.length; i++) {
        idx = _advance(items, idx);
        visited.add(idx);
      }
      expect(visited, [0, 1, 2, 3, 0]);
    });
  });

  group('foreground phone (non-car): youtube rows are NEVER skipped', () {
    // Regression for the reported "jumps two items / skips the YouTube iframe
    // row" bug. On a foreground phone route (skipYoutube == false), a failing
    // item MUST advance to the immediate next row even when that row is a
    // youtube / youtube_playlist item — never over it. (Only car/cast, i.e.
    // skipYoutube == true, may step over youtube rows.)

    test('A(audio) fails → lands on B(youtube), the immediate next row', () {
      final items = [
        _item(1, PlaylistItemType.audio), // 0 — A, fails
        _item(2, PlaylistItemType.youtube), // 1 — B, the iframe row
        _item(3, PlaylistItemType.audio), // 2 — C
      ];
      final next = _advance(items, 0); // skipYoutube: false (phone)
      expect(next, 1, reason: 'must NOT skip the youtube row to land on C');
      expect(items[next].type, PlaylistItemType.youtube);
    });

    test('A(video) fails → lands on B(youtube_playlist), immediate next row',
        () {
      final items = [
        _item(1, PlaylistItemType.video), // 0 — A, fails
        _item(2, PlaylistItemType.youtubePlaylist), // 1 — B
        _item(3, PlaylistItemType.audio), // 2 — C
      ];
      final next = _advance(items, 0);
      expect(next, 1);
      expect(items[next].type, PlaylistItemType.youtubePlaylist);
    });

    test('a youtube item that fails → lands on the very next row (down)', () {
      final items = [
        _item(1, PlaylistItemType.audio), // 0
        _item(2, PlaylistItemType.youtube), // 1 — fails
        _item(3, PlaylistItemType.youtube), // 2 — the next row, also youtube
        _item(4, PlaylistItemType.audio), // 3
      ];
      // From the failing youtube at index 1, next row is the youtube at 2 —
      // it must land there, not jump to the audio at 3.
      expect(_advance(items, 1), 2);
    });

    test('two youtube rows in a row: failing the first lands on the second', () {
      final items = [
        _item(21, PlaylistItemType.youtubePlaylist), // 0 — fails
        _item(22, PlaylistItemType.youtube), // 1 — next row
      ];
      expect(_advance(items, 0), 1);
    });
  });

  group('advance step-overs keep going DOWN (never reverse)', () {
    test('car/cast skips youtube + youtube_playlist while advancing down', () {
      final items = _mediaMixNewestFirst();
      // From video (1): the two youtube rows below are skipped, wrap to audio.
      expect(_advance(items, 1, skipYoutube: true), 0);
      // From audio (0): next playable going down (video at 1).
      expect(_advance(items, 0, skipYoutube: true), 1);
    });

    test('unknown (unplayable) kinds are stepped over downward', () {
      final items = [
        _item(1, PlaylistItemType.audio), // 0
        _item(2, PlaylistItemType.unknown), // 1 — skip
        _item(3, PlaylistItemType.unknown), // 2 — skip
        _item(4, PlaylistItemType.audio), // 3
      ];
      expect(_advance(items, 0), 3, reason: 'skip the two unknowns downward');
      expect(_advance(items, 3), 0, reason: 'wrap past nothing playable below');
    });

    test('nothing playable (all youtube in car) yields -1, no reverse', () {
      final items = [
        _item(1, PlaylistItemType.youtube),
        _item(2, PlaylistItemType.youtubePlaylist),
      ];
      expect(_advance(items, 0, skipYoutube: true), -1);
    });
  });

  group('reconcile-removal advance also walks DOWN (newest-first)', () {
    test('removing the current item advances to the next row DOWN', () {
      // Displayed newest-first [1,2,3,4]; playing id 2 (index 1) is removed.
      // The survivor DOWN the list (id 3) must win — not id 1 above it.
      final result = PlaylistReconciler.reconcile(
        current: [
          _item(1, PlaylistItemType.audio),
          _item(2, PlaylistItemType.audio),
          _item(3, PlaylistItemType.audio),
          _item(4, PlaylistItemType.audio),
        ],
        currentIndex: 1,
        incoming: [
          _item(1, PlaylistItemType.audio),
          _item(3, PlaylistItemType.audio),
          _item(4, PlaylistItemType.audio),
        ],
      );
      expect(result.currentItemRemoved, isTrue);
      expect(result.items[result.currentIndex].id, 3);
    });
  });
}
