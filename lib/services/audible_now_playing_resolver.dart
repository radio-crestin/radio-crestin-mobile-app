import 'package:radio_crestin/services/audible_song_policy.dart';
import 'package:radio_crestin/services/hls_timeline.dart' show SongBoundaryHint;

/// Where an audible now-playing came from.
enum AudibleSource {
  /// The playlist's B14 attributes (no request).
  tag,

  /// The live list, when it provably covers the instant (no request).
  live,

  /// `/stations-metadata-history`.
  history,
}

/// The song the listener hears on time-shifted HLS, for one station.
class AudibleNowPlaying {
  const AudibleNowPlaying({
    required this.stationId,
    required this.row,
    required this.source,
    required this.heardAt,
    this.settled = true,
  });

  final int stationId;
  final NowPlayingRow row;
  final AudibleSource source;

  /// B for a change, A for an anchor: the recently-played cutoff while the
  /// audible instant is unknown (pause disconnect, reload).
  final DateTime heardAt;

  /// False when an anchor came from a response generated too soon after
  /// [heardAt] to hold every row starting just before it (instant mode):
  /// worth one re-check once ingestion has caught up.
  final bool settled;
}

/// Finds the song a listener hears on time-shifted HLS.
///
/// The latest request wins: starting a newer resolution makes every older one
/// return null at its next await, so out-of-order responses can never apply
/// an older song after a newer one.
class AudibleNowPlayingResolver {
  AudibleNowPlayingResolver({
    required this.fetchHistory,
    required this.now,
    required this.wait,
  });

  /// One history request; null when it failed (HTTP, timeout, API error).
  final Future<HistoryPage?> Function(String slug, HistoryWindow window)
      fetchHistory;
  final DateTime Function() now;
  final Future<void> Function(Duration) wait;

  int _ticket = 0;

  /// Ticket of the resolution waiting for a response or a retry delay.
  int? _inFlightTicket;

  /// Whether the latest resolution is still waiting for a response or a
  /// retry delay.
  ///
  /// A superseded or cancelled one can still be waiting (up to the 30 s
  /// retry delay), but its result is discarded, so it does not count:
  /// otherwise a station switch would block the next station's safety-net
  /// checks until that wait ran out.
  bool get isBusy => _inFlightTicket == _ticket;

  /// Makes every in-flight resolution return null.
  void cancelAll() => _ticket++;

  /// The song that starts at [boundary] (the audible instant reached it).
  ///
  /// In order: the playlist hint, the live row when it starts exactly at
  /// [boundary], then the history window around it, retried with a new cache
  /// key until the row is ingested or a settled response proves it absent.
  /// [songBefore] is the song audible before the boundary, if known.
  Future<AudibleNowPlaying?> resolveChange({
    required int stationId,
    required String slug,
    required DateTime boundary,
    SongBoundaryHint? hint,
    NowPlayingRow? live,
    int? songBefore,
  }) async {
    final ticket = ++_ticket;
    AudibleNowPlaying found(NowPlayingRow row, AudibleSource source) =>
        AudibleNowPlaying(
            stationId: stationId, row: row, source: source, heardAt: boundary);
    final tagged = AudibleSongPolicy.nowPlayingFromHint(hint, boundary);
    if (tagged != null) {
      final row =
          NowPlayingRow(startedAt: boundary.toUtc(), nowPlaying: tagged);
      return found(row, AudibleSource.tag);
    }
    if (live != null &&
        AudibleSongPolicy.isExactChangeRow(live, boundary) &&
        (songBefore == null || live.songId != songBefore)) {
      return found(live, AudibleSource.live);
    }
    return _withRetries<AudibleNowPlaying>(ticket, (attempt) async {
      final window = AudibleSongPolicy.changeWindow(
          boundary: boundary, attempt: attempt, nowEpoch: _nowEpoch);
      final page = await fetchHistory(slug, window);
      if (page == null) return const _Retry();
      final row = AudibleSongPolicy.changeRow(page.rows, boundary,
          songBefore: songBefore);
      if (row != null) return _Done(found(row, AudibleSource.history));
      return AudibleSongPolicy.isSettled(page.generatedAt, boundary)
          ? const _GiveUp()
          : const _Retry();
    });
  }

  /// The song audible at [audible] after a (re)anchor.
  ///
  /// The live row when the live list ([liveCursor], Unix seconds) provably
  /// covers [audible]; otherwise the newest row at or before [audible] among
  /// the last hour of history, the live row and [heard] (a cached history
  /// copy can miss the latest rows). Nothing found keeps the current title:
  /// there is never a live-clock fallback.
  ///
  /// [heard] is the station's current audible song. A known-heard row that
  /// started by [audible] can then never be replaced by an older one from a
  /// stale copy, while a re-anchor further back (it started after
  /// [audible]) still shows the older song.
  Future<AudibleNowPlaying?> resolveAnchor({
    required int stationId,
    required String slug,
    required DateTime audible,
    NowPlayingRow? live,
    AudibleNowPlaying? heard,
    required int liveCursor,
  }) async {
    final ticket = ++_ticket;
    if (live != null &&
        AudibleSongPolicy.liveProvesAudible(
            live: live, audible: audible, liveCursor: liveCursor)) {
      return AudibleNowPlaying(
          stationId: stationId,
          row: live,
          source: AudibleSource.live,
          heardAt: audible);
    }
    return _withRetries<AudibleNowPlaying>(ticket, (attempt) async {
      final window =
          AudibleSongPolicy.anchorWindow(audible: audible, nowEpoch: _nowEpoch);
      final page = await fetchHistory(slug, window);
      if (page == null) return const _Retry();
      final heardRow = heard?.stationId == stationId ? heard!.row : null;
      // Live and heard go first so that, on a tie, history's order decides.
      final row = AudibleSongPolicy.rowAt([
        if (live != null) live,
        if (heardRow != null) heardRow,
        ...page.rows,
      ], audible);
      if (row == null) return const _GiveUp();
      return _Done(AudibleNowPlaying(
        stationId: stationId,
        row: row,
        source: identical(row, live)
            ? AudibleSource.live
            : identical(row, heardRow)
                ? heard!.source
                : AudibleSource.history,
        heardAt: audible,
        settled: AudibleSongPolicy.isSettled(page.generatedAt, audible),
      ));
    });
  }

  int get _nowEpoch => now().millisecondsSinceEpoch ~/ 1000;

  /// Runs [attempt] up to `retryDelays.length + 1` times, waiting
  /// [AudibleSongPolicy.retryDelays] between retries. Returns null when
  /// superseded, given up or out of attempts.
  Future<T?> _withRetries<T>(
    int ticket,
    Future<_Attempt<T>> Function(int attempt) attempt,
  ) async {
    _inFlightTicket = ticket;
    try {
      const delays = AudibleSongPolicy.retryDelays;
      for (var i = 0; i <= delays.length; i++) {
        final outcome = await _guarded(attempt, i);
        if (ticket != _ticket) return null;
        switch (outcome) {
          case _Done(:final value):
            return value;
          case _GiveUp():
            return null;
          case _Retry():
            if (i == delays.length) return null;
        }
        await wait(delays[i]);
        if (ticket != _ticket) return null;
      }
      return null;
    } finally {
      if (_inFlightTicket == ticket) _inFlightTicket = null;
    }
  }

  static Future<_Attempt<T>> _guarded<T>(
    Future<_Attempt<T>> Function(int attempt) attempt,
    int i,
  ) async {
    try {
      return await attempt(i);
    } catch (_) {
      return _Retry<T>();
    }
  }
}

/// The outcome of one attempt.
sealed class _Attempt<T> {
  const _Attempt();
}

/// Found: stop with [value].
final class _Done<T> extends _Attempt<T> {
  const _Done(this.value);
  final T value;
}

/// Proven absent (settled response): stop, keep the current title.
final class _GiveUp<T> extends _Attempt<T> {
  const _GiveUp();
}

/// Not ingested yet, a stale copy, or a failed request: try again.
final class _Retry<T> extends _Attempt<T> {
  const _Retry();
}
