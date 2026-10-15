/// What the CarPlay "Home" tab shows, computed from plain data so the rules
/// can be unit tested without the CarPlay plugin.
///
/// Every list holds station slugs, in display order.
class CarHomeLayout {
  const CarHomeLayout({
    required this.pinned,
    required this.hiddenFavoriteCount,
    required this.favorites,
    required this.all,
  });

  /// Most stations in the pinned row, even when CarPlay takes more, so the
  /// row stays at about two lines and the station list stays in view.
  static const maxPinnedRow = 8;

  /// Favorites in the pinned row at the top of the list (iOS 26+), most
  /// played first, then in the listener's order.
  final List<String> pinned;

  /// Favorites that did not fit in [pinned]. When above zero, the row ends
  /// with a picture that opens every favorite.
  final int hiddenFavoriteCount;

  /// The "Favorites" section, in the listener's order, used only where
  /// there is no pinned row.
  final List<String> favorites;

  /// The "All stations" section.
  final List<String> all;

  /// Whether the listener has favorites; without any, Home shows how to add
  /// them where they would be.
  bool get hasFavorites => pinned.isNotEmpty || favorites.isNotEmpty;

  /// Lays out the Home list.
  ///
  /// [sortedSlugs] is the app's station order. [favoriteSlugs] are the
  /// favorites in the listener's order, which breaks ties in the pinned row.
  /// [maxPinned] is how many stations CarPlay shows in the pinned row; the
  /// row holds at most [maxPinnedRow] of them. It is used only when
  /// [usePinnedRow] is true and at least two fit, since an overflowing row
  /// needs one slot for "all favorites".
  factory CarHomeLayout.compute({
    required List<String> sortedSlugs,
    required List<String> favoriteSlugs,
    required Map<String, int> playCounts,
    required bool usePinnedRow,
    required int maxPinned,
  }) {
    final listed = sortedSlugs.toSet();
    final favorites =
        favoriteSlugs.where(listed.contains).toList(growable: false);
    final rowSize = maxPinned < maxPinnedRow ? maxPinned : maxPinnedRow;
    final withPinnedRow = usePinnedRow && rowSize >= 2;

    var pinned = const <String>[];
    var hiddenFavoriteCount = 0;
    if (withPinnedRow && favorites.isNotEmpty) {
      final byPlays = _byCountDescending(favorites, playCounts);
      if (byPlays.length <= rowSize) {
        pinned = byPlays;
      } else {
        pinned = byPlays.take(rowSize - 1).toList(growable: false);
        hiddenFavoriteCount = byPlays.length - pinned.length;
      }
    }

    return CarHomeLayout(
      pinned: pinned,
      hiddenFavoriteCount: hiddenFavoriteCount,
      favorites: withPinnedRow ? const [] : favorites,
      all: List.unmodifiable(sortedSlugs),
    );
  }

  /// [slugs] by [counts], highest first; equal counts keep their order.
  static List<String> _byCountDescending(
    List<String> slugs,
    Map<String, int> counts,
  ) {
    final indexed = [for (var i = 0; i < slugs.length; i++) (i, slugs[i])];
    indexed.sort((a, b) {
      final byCount = (counts[b.$2] ?? 0).compareTo(counts[a.$2] ?? 0);
      return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }
}

/// A station group as the car "Categories" tab shows it.
class CarCategory {
  const CarCategory({
    required this.id,
    required this.slug,
    required this.name,
    required this.stationIds,
  });

  final int id;
  final String slug;
  final String name;

  /// The group's stations that the app knows about.
  final Set<int> stationIds;

  /// The SF Symbol for this category's grid button.
  String get symbol => _symbols[slug] ?? 'square.grid.2x2';

  static const _symbols = {
    'general': 'radio',
    'muzica': 'music.note',
    'emisiuni': 'dot.radiowaves.left.and.right',
    'popular': 'guitars',
    'predici': 'mic',
    'worship': 'sparkles',
    'international': 'globe',
    'gospel': 'music.mic',
    'instrumental': 'pianokeys',
    'copii': 'figure.and.child.holdinghands',
    'biblia': 'book.closed',
    'colinde': 'snowflake',
  };
}

/// The car "Categories" grid: the categories that get their own button and
/// the rest, reached through a final "More" button.
class CarCategoryLayout {
  const CarCategoryLayout({required this.onGrid, required this.more});

  /// Most buttons a CarPlay grid shows.
  static const maxGridButtons = 8;

  /// Categories that keep their own button when not all fit, in the last
  /// places before "More": children's programs and the Bible matter more
  /// in the car than the groups the API lists before them.
  static const alwaysOnGrid = ['copii', 'biblia'];

  /// Categories with their own grid button: API order, then [alwaysOnGrid].
  final List<CarCategory> onGrid;

  /// Categories behind the "More" button; empty when every one fits.
  final List<CarCategory> more;

  bool get isEmpty => onGrid.isEmpty;

  /// Lays out [groups] (in API order) for the grid.
  ///
  /// Groups with none of [knownStationIds] are dropped, and so is a group
  /// holding every grouped station (the API's "all" group): it repeats the
  /// "All stations" list. Private stations belong to no group, so they don't
  /// count. When more than [maxGridButtons] remain, the last button becomes
  /// "More" and the [alwaysOnGrid] categories take the places before it.
  factory CarCategoryLayout.compute({
    required List<CarCategory> groups,
    required Set<int> knownStationIds,
  }) {
    final grouped = {
      for (final group in groups)
        ...group.stationIds.intersection(knownStationIds),
    };
    final visible = <CarCategory>[];
    for (final group in groups) {
      final ids = group.stationIds.intersection(knownStationIds);
      if (ids.isEmpty || ids.length == grouped.length) continue;
      visible.add(CarCategory(
        id: group.id,
        slug: group.slug,
        name: group.name,
        stationIds: ids,
      ));
    }
    if (visible.length <= maxGridButtons) {
      return CarCategoryLayout(onGrid: visible, more: const []);
    }
    final kept = [
      for (final slug in alwaysOnGrid)
        ...visible.where((c) => c.slug == slug),
    ];
    final rest = visible.where((c) => !kept.contains(c)).toList();
    final fromRest = maxGridButtons - 1 - kept.length;
    return CarCategoryLayout(
      onGrid: [...rest.take(fromRest), ...kept],
      more: rest.skip(fromRest).toList(growable: false),
    );
  }

  /// A fingerprint of what the grid shows, to skip rebuilding it when a
  /// catalog refresh changed nothing visible.
  String get signature => [
        for (final c in [...onGrid, ...more])
          '${c.id}:${c.name}:${c.stationIds.length}',
        'more:${more.length}',
      ].join('|');
}
