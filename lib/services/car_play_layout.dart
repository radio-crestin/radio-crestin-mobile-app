/// Wording that CarPlay and Android Auto share, so both cars name their lists
/// and rows the same way. Car screens are in Romanian only, like the app.
abstract final class CarStrings {
  static const favorites = 'Favorite';
  static const categories = 'Categorii';
  static const songHistory = 'Redate recent';

  /// The first entry of Categorii, which lists every station.
  static const allStations = 'Toate radiourile';

  /// A favorite's title in a list that mixes it with other stations.
  static String starred(String title) => '★ $title';

  /// [starred] on Android Auto, with the star after the name: its A·Z
  /// index files a row under the first character of its title, so
  /// "★ RVE Brasov" would sit under "#" instead of "R".
  static String starredOnAndroidAuto(String title) => '$title ★';
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

  /// The drawable for this category's Android Auto row: the Material
  /// counterpart of [symbol], white, in `res/drawable`.
  String get androidIcon => _symbols.containsKey(slug)
      ? 'ic_category_$slug'
      : 'ic_category_other';

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

  /// Category buttons on the grid, "More" included: the first button
  /// lists every station ([CarStrings.allStations]).
  static const maxCategoryButtons = maxGridButtons - 1;

  /// Categories the car shows first, in this order, ahead of the others in
  /// API order (the listener's choice, 2026-10-18).
  static const firstInCar = ['general', 'copii', 'popular'];

  /// Categories with their own button: [firstInCar], then API order.
  final List<CarCategory> onGrid;

  /// Categories behind the "More" button; empty when every one fits.
  final List<CarCategory> more;

  /// Every category in the order a driver meets them: the grid buttons,
  /// then the categories behind "More".
  List<CarCategory> get all => [...onGrid, ...more];

  /// Lays out [groups] (in API order) for the grid.
  ///
  /// Groups with none of [knownStationIds] are dropped, and so is a group
  /// holding every grouped station (the API's "all" group): it repeats the
  /// "All stations" list. Private stations belong to no group, so they don't
  /// count. The [firstInCar] categories lead. When more than
  /// [maxCategoryButtons] remain, the last one becomes "More".
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
    final first = [
      for (final slug in firstInCar) ...visible.where((c) => c.slug == slug),
    ];
    final ordered = [
      ...first,
      ...visible.where((c) => !first.contains(c)),
    ];
    if (ordered.length <= maxCategoryButtons) {
      return CarCategoryLayout(onGrid: ordered, more: const []);
    }
    const shown = maxCategoryButtons - 1;
    return CarCategoryLayout(
      onGrid: ordered.take(shown).toList(growable: false),
      more: ordered.skip(shown).toList(growable: false),
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
