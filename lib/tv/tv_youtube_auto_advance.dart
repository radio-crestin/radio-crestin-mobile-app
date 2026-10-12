import 'dart:async';

import 'package:flutter/foundation.dart';

import '../types/playlist_item.dart';

/// How long TV and desktop show a YouTube item before moving past it.
const Duration kTvYoutubeAutoAdvanceDelay = Duration(seconds: 4);

/// A running countdown: the item [itemId] is moved past at [deadline].
typedef TvYoutubeCountdown = ({int itemId, DateTime deadline});

/// Moves a playlist past YouTube items on TV and desktop, where they cannot
/// be embedded.
///
/// The "up next" card only exists while Now Playing is on screen, so without
/// this the playlist would stall silently on a YouTube item whenever the user
/// is browsing. Every non-null request re-arms the countdown, including a
/// repeat of the same item (a playlist looping one YouTube entry); a null
/// request cancels it.
///
/// The countdown only runs while the listener wants playback: a pause
/// cancels it, so a paused playlist never starts the next item by itself,
/// and a resume restarts the full [delay].
///
/// The card renders [countdown] instead of keeping a timer of its own, so
/// its bar ends when the playlist actually advances, even when Now Playing
/// is opened partway through.
class TvYoutubeAutoAdvance {
  /// Listens to [requests] (the YouTube item on screen) and [shouldPlay]
  /// (the play intent), and calls [onAdvance] with the item id once an item
  /// has been showing, unpaused, for [delay].
  TvYoutubeAutoAdvance({
    required Stream<PlaylistItem?> requests,
    required Stream<bool> shouldPlay,
    required void Function(int itemId) onAdvance,
    this.delay = kTvYoutubeAutoAdvanceDelay,
  }) : _onAdvance = onAdvance {
    _subscriptions = [
      requests.listen((item) {
        _item = item;
        _rearm();
      }),
      // A repeated `true` must not restart a countdown that is running.
      shouldPlay.distinct().listen((play) {
        _playing = play;
        _rearm();
      }),
    ];
  }

  /// Time an item stays on screen, unpaused, before it is moved past.
  final Duration delay;

  final void Function(int itemId) _onAdvance;
  late final List<StreamSubscription<Object?>> _subscriptions;
  final ValueNotifier<TvYoutubeCountdown?> _countdown = ValueNotifier(null);
  PlaylistItem? _item;
  bool _playing = true;
  Timer? _timer;

  /// The running countdown, or null while no YouTube item is showing or the
  /// listener paused.
  ValueListenable<TvYoutubeCountdown?> get countdown => _countdown;

  void _rearm() {
    _timer?.cancel();
    _timer = null;
    final item = _item;
    if (item == null || !_playing) {
      _countdown.value = null;
      return;
    }
    _countdown.value = (itemId: item.id, deadline: DateTime.now().add(delay));
    _timer = Timer(delay, () => _onAdvance(item.id));
  }

  /// Cancels the pending countdown and stops listening.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _countdown.dispose();
  }
}
