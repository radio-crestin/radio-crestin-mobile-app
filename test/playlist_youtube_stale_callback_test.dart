import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/playlist_controller.dart';
import 'package:radio_crestin/services/playlist_sync_service.dart';
import 'package:radio_crestin/services/video_playback_service.dart';
import 'package:radio_crestin/types/playlist_item.dart';

/// Root-cause regression tests for the "auto-advance skips the YouTube row /
/// jumps two items" bug.
///
/// The full player keeps two inline YouTube iframes briefly mounted during the
/// 250ms crossfade between youtube items. The OUTGOING iframe (for the item we
/// just left) could fire a late error/ended event; the controller's guard only
/// checked *whether* the current item was youtube, so it treated that stale
/// event as the NEW item failing and advanced again — skipping the youtube row
/// that had just started. The fix scopes every youtube callback to the
/// reporting item's id: a callback whose id != the current item's id is
/// ignored. These tests pin exactly that (the stale path returns before any
/// [AppAudioHandler] access, so no handler registration is needed).
PlaylistItem _yt(int id) => PlaylistItem(
      id: id,
      order: id,
      type: PlaylistItemType.youtube,
      url: 'https://youtu.be/vid$id',
      title: 'YT $id',
    );

PlaylistController _controller() => PlaylistController(
      videoService: VideoPlaybackService(),
      syncService: PlaylistSyncService(),
    );

void main() {
  group('stale youtube callbacks are ignored (scoped by item id)', () {
    late PlaylistController c;

    setUp(() {
      c = _controller();
      // Two youtube rows; item 2 is the CURRENT (just-started) one, item 1 is
      // the outgoing iframe still fading out.
      c.items.add([_yt(1), _yt(2)]);
      c.currentIndex.add(1);
      c.currentItem.add(_yt(2));
    });

    test('a stale error from the OUTGOING iframe does not advance', () {
      c.notifyYoutubeItemError(itemId: 1); // late error for the left item
      expect(c.currentIndex.value, 1, reason: 'stale error must be ignored');
    });

    test('a stale ended from the OUTGOING iframe does not advance', () {
      c.notifyYoutubeItemEnded(itemId: 1);
      expect(c.currentIndex.value, 1);
    });

    test('stale playing/position reports short-circuit before handler access',
        () {
      // For a MATCHING id these reach AppAudioHandler (unregistered here); the
      // fact the stale id returns cleanly proves the guard short-circuits.
      c.notifyYoutubePlaying(true, itemId: 1);
      c.notifyYoutubePosition(
          const Duration(seconds: 5), const Duration(seconds: 30), itemId: 1);
      expect(c.currentIndex.value, 1);
      expect(c.failedItemIds.value, isEmpty);
    });
  });
}
