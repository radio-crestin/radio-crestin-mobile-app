/// Song attributes the playlist attached to a song boundary (backend B14).
///
/// Parsed from the optional `X-TITLE`, `X-ARTIST`, `X-SONG-ID`,
/// `X-ARTIST-ID` and `X-THUMBNAIL-URL` attributes of
/// `#EXT-X-RC-METADATA-CHANGED`. The backend only emits them once it accepted
/// a report for that exact song instance, so they equal what the API returns
/// and the metadata layer may show them without a round trip.
class SongBoundaryHint {
  final String? title;
  final String? artist;
  final String? thumbnailUrl;
  final int? songId;
  final int? artistId;

  const SongBoundaryHint({
    this.title,
    this.artist,
    this.thumbnailUrl,
    this.songId,
    this.artistId,
  });

  /// True when the tag carried none of the optional attributes.
  bool get isEmpty =>
      title == null &&
      artist == null &&
      thumbnailUrl == null &&
      songId == null &&
      artistId == null;

  @override
  bool operator ==(Object other) =>
      other is SongBoundaryHint &&
      other.title == title &&
      other.artist == artist &&
      other.thumbnailUrl == thumbnailUrl &&
      other.songId == songId &&
      other.artistId == artistId;

  @override
  int get hashCode =>
      Object.hash(title, artist, thumbnailUrl, songId, artistId);

  @override
  String toString() =>
      'SongBoundaryHint(songId: $songId, title: $title, artist: $artist)';
}

/// A song change announced by the playlist, in server wall-clock time.
///
/// Sources: `EXT-X-RC-METADATA-CHANGED` `EPOCH`, and every
/// `EXT-X-DATERANGE` `START-DATE` / `END-DATE`.
class SongBoundary {
  final DateTime at;
  final SongBoundaryHint? hint;

  const SongBoundary(this.at, {this.hint});

  /// This boundary with [newer]'s hint when that one carries attributes.
  ///
  /// The backend publishes the same `EPOCH` first without and seconds later
  /// with the B14 attributes, so a later sighting may only add a hint, never
  /// remove one.
  SongBoundary mergedWith(SongBoundary newer) {
    final newHint = newer.hint;
    if (newHint == null || newHint.isEmpty) return this;
    return SongBoundary(at, hint: newHint);
  }

  @override
  String toString() => 'SongBoundary(${at.toIso8601String()}, $hint)';
}

/// What to do about one song boundary right now.
enum MetadataAlignmentAction {
  /// The audible instant reached the boundary: refresh now.
  refreshNow,

  /// The listener hears the boundary after
  /// [MetadataAlignmentDecision.delay].
  scheduleAfterDelay,

  /// No audible instant yet (the timeline is still anchoring): keep the
  /// boundary and decide once the clock is known.
  waitForClock,

  /// The boundary lies further in the future than the wall clock allows (a
  /// backend clock fault). Kept and re-evaluated on every plan, never
  /// dropped.
  aheadOfWallClock,
}

class MetadataAlignmentDecision {
  final MetadataAlignmentAction action;

  /// Only meaningful for [MetadataAlignmentAction.scheduleAfterDelay].
  final Duration delay;

  const MetadataAlignmentDecision(this.action, [this.delay = Duration.zero]);
}

/// Pure alignment policy for one song boundary against the audible instant.
///
/// The playlist announces a song change on the live timeline, but the
/// listener hears it one latency later (2-5 min with the pre-buffer
/// setting). Refreshing when the tag is seen would show the next title while
/// the previous song still plays.
class MetadataChangeAlignment {
  /// Boundaries this close ahead of the audible instant count as reached.
  /// Smaller than the 10 s poll so a poll landing on the change is not
  /// deferred by clock jitter.
  static const Duration nowTolerance = Duration(seconds: 2);

  /// How far past the wall clock a boundary may lie before it is treated as
  /// a backend clock fault. There is no cap relative to the audible instant:
  /// a real boundary happened at or before wall-clock now, so it is at most
  /// one listening latency ahead of the audible instant, whatever the
  /// offset.
  static const Duration futureGuard = Duration(seconds: 30);

  static MetadataAlignmentDecision decide({
    required DateTime? audibleNow,
    required DateTime boundary,
    required DateTime wallNow,
  }) {
    if (audibleNow == null) {
      return const MetadataAlignmentDecision(
          MetadataAlignmentAction.waitForClock);
    }
    if (boundary.isAfter(wallNow.add(futureGuard))) {
      return const MetadataAlignmentDecision(
          MetadataAlignmentAction.aheadOfWallClock);
    }
    if (!boundary.isAfter(audibleNow.add(nowTolerance))) {
      return const MetadataAlignmentDecision(
          MetadataAlignmentAction.refreshNow);
    }
    return MetadataAlignmentDecision(
      MetadataAlignmentAction.scheduleAfterDelay,
      boundary.difference(audibleNow),
    );
  }
}

/// Every song boundary the playlist announced that the listener has not
/// heard yet.
///
/// Replaces the single re-armed timer, which lost every boundary but the
/// last when several were ahead of the listener (a 5-min offset over short
/// items). The owner keeps one timer for [delayUntilNext] and asks
/// [takeReached] when it fires. Pure: time is always passed in.
class SongBoundaryQueue {
  /// Boundaries closer than this are the same song change (EPOCH vs the
  /// previous song's END-DATE vs the next song's START-DATE).
  static const Duration dedupeWindow = Duration(seconds: 2);

  /// Upper bound on pending boundaries. A 5-min offset over 18 s jingles
  /// needs ~17.
  static const int maxPending = 32;

  /// Consumed boundaries kept so a backward step of the audible instant can
  /// reopen them.
  static const int maxConsumed = 8;

  /// Boundaries remembered so the 11-minute window does not re-add the same
  /// ones on every poll. Above the window's worst case (~40).
  static const int maxKnown = 128;

  final List<SongBoundary> _pending = [];
  final List<SongBoundary> _consumed = [];
  final List<DateTime> _known = [];

  /// Pending boundaries, earliest first.
  List<SongBoundary> get pending => List.unmodifiable(_pending);

  /// Queues new boundaries and upgrades the hint of known ones.
  void add(Iterable<SongBoundary> boundaries) {
    for (final b in boundaries) {
      if (_mergeInto(_pending, b) || _mergeInto(_consumed, b)) continue;
      if (_isKnown(b.at)) continue;
      _pending.add(b);
      _remember(b.at);
    }
    _pending.sort((a, b) => a.at.compareTo(b.at));
    _enforcePendingCap();
  }

  /// Drops every boundary at or before [audibleNow]. Used when the clock
  /// (re)anchors: the anchored refresh resolves the song audible at
  /// [audibleNow], which covers exactly these.
  ///
  /// Unlike [takeReached], no [MetadataChangeAlignment.nowTolerance]: a
  /// boundary just after the instant is not what the anchor resolves, so it
  /// stays pending and the next [takeReached] issues its change refresh.
  /// Dropping it too would mark that song as heard and never show it.
  void dropHeard(DateTime audibleNow) => _consumeUpTo(audibleNow);

  /// Removes every reached boundary and returns the newest of them, so a
  /// late timer or a re-plan produces a single refresh.
  SongBoundary? takeReached(DateTime audibleNow) {
    final reached =
        _consumeUpTo(audibleNow.add(MetadataChangeAlignment.nowTolerance));
    return reached.isEmpty ? null : reached.last;
  }

  /// Delay until the earliest pending boundary that can be scheduled, or
  /// null when none can (empty, or every one is ahead of the wall clock).
  Duration? delayUntilNext(DateTime audibleNow, DateTime wallNow) {
    for (final b in _pending) {
      final d = MetadataChangeAlignment.decide(
          audibleNow: audibleNow, boundary: b.at, wallNow: wallNow);
      switch (d.action) {
        case MetadataAlignmentAction.refreshNow:
          return Duration.zero;
        case MetadataAlignmentAction.scheduleAfterDelay:
          return d.delay;
        case MetadataAlignmentAction.waitForClock:
        case MetadataAlignmentAction.aheadOfWallClock:
          continue;
      }
    }
    return null;
  }

  /// Moves consumed boundaries that lie ahead of [audibleNow] back to
  /// pending, and returns whether any moved.
  ///
  /// Only matters when the audible instant steps back: the skew estimator's
  /// warm-up, or a re-anchor. A boundary consumed at `B <= A + 2 s` is
  /// reopened only if `A` really moved back.
  bool reopenAfter(DateTime audibleNow) {
    final limit = audibleNow.add(MetadataChangeAlignment.nowTolerance);
    final reopened = _consumed.where((b) => b.at.isAfter(limit)).toList();
    if (reopened.isEmpty) return false;
    _consumed.removeWhere(reopened.contains);
    _pending
      ..addAll(reopened)
      ..sort((a, b) => a.at.compareTo(b.at));
    return true;
  }

  void clear() {
    _pending.clear();
    _consumed.clear();
    _known.clear();
  }

  /// Moves every pending boundary at or before [limit] to consumed and
  /// returns them, earliest first.
  List<SongBoundary> _consumeUpTo(DateTime limit) {
    final reached = _pending.where((b) => !b.at.isAfter(limit)).toList();
    if (reached.isEmpty) return reached;
    _pending.removeWhere(reached.contains);
    _consumed.addAll(reached);
    if (_consumed.length > maxConsumed) {
      _consumed.removeRange(0, _consumed.length - maxConsumed);
    }
    return reached;
  }

  /// Merges [b] into a boundary of [list] within [dedupeWindow]; returns
  /// whether one matched. The first sighting keeps its instant.
  bool _mergeInto(List<SongBoundary> list, SongBoundary b) {
    final i = list.indexWhere((e) => _sameChange(e.at, b.at));
    if (i < 0) return false;
    list[i] = list[i].mergedWith(b);
    return true;
  }

  bool _isKnown(DateTime at) => _known.any((k) => _sameChange(k, at));

  void _remember(DateTime at) {
    _known.add(at);
    if (_known.length > maxKnown) {
      _known.removeRange(0, _known.length - maxKnown);
    }
  }

  /// Keeps the earliest [maxPending] boundaries. The dropped (furthest
  /// ahead) ones are forgotten too, so a later poll can bring them back.
  void _enforcePendingCap() {
    if (_pending.length <= maxPending) return;
    final dropped = _pending.sublist(maxPending);
    _pending.removeRange(maxPending, _pending.length);
    for (final b in dropped) {
      _known.removeWhere((k) => _sameChange(k, b.at));
    }
  }

  static bool _sameChange(DateTime a, DateTime b) =>
      a.difference(b).abs() <= dedupeWindow;
}
