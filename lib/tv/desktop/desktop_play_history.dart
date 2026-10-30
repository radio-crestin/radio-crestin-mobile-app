/// The stations played in the window, for the mouse's back and forward
/// buttons to go through as a browser's go through the pages visited: back
/// plays the station played before the current one, forward the one back
/// left.
class DesktopPlayHistory {
  /// [earlier]: the stations played before, oldest first, for back to
  /// reach past the launch.
  DesktopPlayHistory({Iterable<String> earlier = const []})
      : _back = earlier.toList() {
    _trim();
  }

  /// How many stations back reaches.
  static const int capacity = 50;

  final List<String> _back;
  final List<String> _forward = [];
  String? _current;

  /// Notes that [slug] plays now. Unless [back] or [forward] chose it, it
  /// forgets what forward would play, as a link followed in a browser
  /// does.
  void played(String slug) {
    if (slug == _current) return;
    if (_current case final current?) _back.add(current);
    _trim();
    _current = slug;
    _forward.clear();
  }

  /// The station back plays: the latest one played before the current one
  /// that [playable] allows, or null.
  String? back({required bool Function(String slug) playable}) =>
      _step(from: _back, to: _forward, playable: playable);

  /// The station forward plays: the latest one back left that [playable]
  /// allows, or null.
  String? forward({required bool Function(String slug) playable}) =>
      _step(from: _forward, to: _back, playable: playable);

  String? _step({
    required List<String> from,
    required List<String> to,
    required bool Function(String slug) playable,
  }) {
    final at =
        from.lastIndexWhere((slug) => slug != _current && playable(slug));
    if (at < 0) return null;
    final slug = from[at];
    // The ones stepped over can't be played (hidden since) or are the one
    // playing.
    from.removeRange(at, from.length);
    if (_current case final current?) to.add(current);
    _current = slug;
    return slug;
  }

  void _trim() {
    if (_back.length > capacity) {
      _back.removeRange(0, _back.length - capacity);
    }
  }
}
