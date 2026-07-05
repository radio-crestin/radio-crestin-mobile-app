import '../types/playlist_item.dart';

/// Outcome of reconciling a live playlist poll against the playing state.
///
/// [items] is the new authoritative ordered list. [currentIndex] points at the
/// item that should be playing after reconciliation (`-1` when playback should
/// stop). [currentItemRemoved] is true when the previously-playing item is gone
/// from the new list; the controller uses it to decide whether to reload the
/// player (unchanged current item must NOT restart).
class PlaylistReconcileResult {
  const PlaylistReconcileResult({
    required this.items,
    required this.currentIndex,
    required this.currentItemRemoved,
    required this.shouldStop,
  });

  final List<PlaylistItem> items;
  final int currentIndex;
  final bool currentItemRemoved;
  final bool shouldStop;
}

/// Pure reconciliation of a freshly-fetched playlist against what's playing.
///
/// The `/station-playlist` endpoint returns the full ordered list every poll,
/// so this is about preserving playback continuity, not merging: new items are
/// adopted in order, removed items drop out, and the currently-playing item is
/// tracked by id so it never restarts just because unrelated metadata changed.
class PlaylistReconciler {
  const PlaylistReconciler._();

  /// Reconciles [incoming] (authoritative, ordered) against the [current] list
  /// and the [currentIndex] being played.
  ///
  /// Rules:
  ///   - The new list is [incoming], deduplicated by id (first wins) to guard
  ///     against a malformed payload.
  ///   - If the currently-playing item still exists, [currentIndex] follows it
  ///     to its new position and [currentItemRemoved] is false (no restart).
  ///   - If it was removed, advance to the next surviving item by walking
  ///     forward through the OLD order from just after the current item; the
  ///     first id still present in the new list wins. If none survive forward,
  ///     playback stops ([shouldStop] true, [currentIndex] `-1`).
  ///   - An empty [incoming] always stops playback.
  static PlaylistReconcileResult reconcile({
    required List<PlaylistItem> current,
    required int currentIndex,
    required List<PlaylistItem> incoming,
  }) {
    // Dedup incoming by id, preserving order (first occurrence wins).
    final seen = <int>{};
    final newItems = <PlaylistItem>[];
    for (final item in incoming) {
      if (seen.add(item.id)) newItems.add(item);
    }

    if (newItems.isEmpty) {
      return PlaylistReconcileResult(
        items: newItems,
        currentIndex: -1,
        currentItemRemoved: currentIndex >= 0 && currentIndex < current.length,
        shouldStop: true,
      );
    }

    // Nothing was playing — adopt the list, nothing to keep in sync.
    if (currentIndex < 0 || currentIndex >= current.length) {
      return PlaylistReconcileResult(
        items: newItems,
        currentIndex: -1,
        currentItemRemoved: false,
        shouldStop: false,
      );
    }

    final currentId = current[currentIndex].id;
    final newIndexOfCurrent = newItems.indexWhere((i) => i.id == currentId);
    if (newIndexOfCurrent >= 0) {
      // Current item survived — keep playing it at its new position.
      return PlaylistReconcileResult(
        items: newItems,
        currentIndex: newIndexOfCurrent,
        currentItemRemoved: false,
        shouldStop: false,
      );
    }

    // Current item removed — advance to the next survivor in old order.
    for (var i = currentIndex + 1; i < current.length; i++) {
      final survivorIndex = newItems.indexWhere((n) => n.id == current[i].id);
      if (survivorIndex >= 0) {
        return PlaylistReconcileResult(
          items: newItems,
          currentIndex: survivorIndex,
          currentItemRemoved: true,
          shouldStop: false,
        );
      }
    }

    // No surviving item after the removed current — stop.
    return PlaylistReconcileResult(
      items: newItems,
      currentIndex: -1,
      currentItemRemoved: true,
      shouldStop: true,
    );
  }
}

/// Pure navigation over a playlist: what to play next/previous, honoring the
/// car/cast "skip youtube" rule and end-of-list looping.
class PlaylistNavigator {
  const PlaylistNavigator._();

  /// Returns the index of the next playable item relative to [fromIndex].
  ///
  /// [direction] is `+1` for next / auto-advance and `-1` for previous.
  /// [PlaylistItemType.unknown] items are always stepped over (unplayable).
  /// When [skipYoutube] is true (a car or Cast session is connected, where the
  /// inline YouTube player can't run), youtube / youtube_playlist items are
  /// stepped over too. When [loop] is true the search wraps around the ends.
  /// Returns `-1` when no playable item exists (e.g. every remaining item is
  /// youtube in car, or the end was reached without looping).
  ///
  /// Pass [fromIndex] `-1` with `direction: 1, loop: false` to get the first
  /// playable item in the list.
  static int nextPlayableIndex({
    required List<PlaylistItem> items,
    required int fromIndex,
    required bool skipYoutube,
    required bool loop,
    int direction = 1,
  }) {
    final n = items.length;
    if (n == 0) return -1;

    var idx = fromIndex;
    // At most n steps — guarantees termination even when nothing is playable.
    for (var step = 0; step < n; step++) {
      idx += direction;
      if (idx < 0 || idx >= n) {
        if (!loop) return -1;
        idx = (idx % n + n) % n; // wrap into range
      }
      if (_isPlayable(items[idx], skipYoutube: skipYoutube)) return idx;
    }
    return -1;
  }

  /// Whether [item] can be played given the current skip-youtube constraint.
  static bool _isPlayable(PlaylistItem item, {required bool skipYoutube}) {
    // Unrecognized future kinds are never playable — always skip them.
    if (item.type == PlaylistItemType.unknown) return false;
    // YouTube (single or whole playlist) can't run on a car/cast route.
    if (skipYoutube && item.type.isYoutube) return false;
    return true;
  }
}
