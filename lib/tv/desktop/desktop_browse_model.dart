import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../services/station_group_categories.dart';
import '../../types/Station.dart';
import '../../utils/romanian_count.dart';
import '../../utils/station_search.dart';

/// What the desktop browse screen lists, worked out the way the phone's
/// home page does it.
@immutable
class DesktopBrowseContent {
  const DesktopBrowseContent({
    this.favorites = const [],
    this.stations = const [],
    this.shownHidden = const {},
  });

  /// Works out the sections from [listed], the stations the main section
  /// shows in their sorted order, and the listener's [favoriteSlugs].
  ///
  /// The favorites stay in the main section too, as on the phone: liking a
  /// station doesn't make it vanish from where the listener found it, and
  /// the list keeps the next/previous order. While a category is chosen
  /// ([categoryChosen]) the "Favorite" section hides: its favorites are in
  /// the category already, and the rest would only push it down.
  ///
  /// [shownHidden] are the hidden stations among [listed], listed in their
  /// places, dimmed: a category whose stations are all hidden shows them
  /// rather than nothing. They are never among the favorites.
  factory DesktopBrowseContent.compute({
    required List<Station> listed,
    required List<String> favoriteSlugs,
    required bool categoryChosen,
    Set<String> shownHidden = const {},
  }) {
    return DesktopBrowseContent(
      favorites: categoryChosen
          ? const []
          : favoritesIn(listed, favoriteSlugs, hidden: shownHidden),
      stations: listed,
      shownHidden: shownHidden,
    );
  }

  /// The "Favorite" section, in the listener's order; empty while hidden.
  final List<Station> favorites;

  /// The main section: "Toate stațiile", or the chosen category's.
  final List<Station> stations;

  /// The hidden stations [stations] lists in their places, dimmed.
  final Set<String> shownHidden;

  /// Whether the main section lists hidden stations in their places.
  bool get showsHidden => shownHidden.isNotEmpty;

  /// The favorites among [source], in the order of [favoriteSlugs], which
  /// the listener can rearrange on the phone; none of the [hidden] ones.
  static List<Station> favoritesIn(
    Iterable<Station> source,
    List<String> favoriteSlugs, {
    Set<String> hidden = const {},
  }) {
    final bySlug = {for (final station in source) station.slug: station};
    return [
      for (final slug in favoriteSlugs)
        if (!hidden.contains(slug))
          if (bySlug[slug] case final Station station) station,
    ];
  }
}

/// What the desktop search lists for [query] among [stations], in their
/// order: the stations whose names match first, then the ones whose song
/// does, as on the phone (see [searchStations]).
List<Station> desktopSearchResults(Iterable<Station> stations, String query) {
  final found = searchStations(stations, query);
  return [...found.byName, ...found.bySong];
}

/// Which station the keyboard highlight moves to among [results], from
/// [current], one place [down] or up; it wraps around at either end.
///
/// The [skipped] stations, on their way out of the results, are passed
/// over. Without a [current] one among the results, the first station is
/// highlighted going down and the last going up. Null when there is none.
String? movedHighlight(
  List<Station> results,
  String? current, {
  required bool down,
  Set<String> skipped = const {},
}) {
  final slugs = [
    for (final station in results)
      if (!skipped.contains(station.slug)) station.slug as String,
  ];
  if (slugs.isEmpty) return null;
  final index = current == null ? -1 : slugs.indexOf(current);
  if (index < 0) return down ? slugs.first : slugs.last;
  final next = (index + (down ? 1 : -1)) % slugs.length;
  return slugs[next];
}

/// The columns and card size of the desktop station grid for a given
/// width, so the cards fill the row edge to edge.
@immutable
class DesktopGridMetrics {
  const DesktopGridMetrics({
    required this.columns,
    required this.tileWidth,
    required this.tileHeight,
  });

  /// The metrics for a grid [width] wide, its cards at most [maxTileWidth]
  /// wide and [spacing] apart. A card's height is its width, for the square
  /// artwork, plus [extraHeight] for its padding and text.
  ///
  /// The grid takes as many columns as it needs to keep its cards no wider
  /// than [maxTileWidth], and at least [minColumns].
  factory DesktopGridMetrics.forWidth(
    double width, {
    required double maxTileWidth,
    required double spacing,
    required double extraHeight,
    int minColumns = 2,
  }) {
    final available = math.max(0.0, width);
    final columns = math.max(
      minColumns,
      ((available + spacing) / (maxTileWidth + spacing)).ceil(),
    );
    final tileWidth = math.max(
      0.0,
      (available - spacing * (columns - 1)) / columns,
    );
    return DesktopGridMetrics(
      columns: columns,
      tileWidth: tileWidth,
      tileHeight: tileWidth + extraHeight,
    );
  }

  final int columns;
  final double tileWidth;
  final double tileHeight;
}

/// What the desktop screen says above a category's hidden stations shown
/// in their places: "Toate cele 4 stații din Worship sunt ascunse.", or how
/// many still are once some were added back. Null when none is.
String? hiddenInCategoryNote(
  String category, {
  required int hidden,
  required int total,
}) {
  String stations(int count) =>
      romanianCount(count, one: 'stație', many: 'stații');
  if (hidden <= 0) return null;
  if (hidden >= total) {
    return total == 1
        ? 'Singura stație din $category e ascunsă.'
        : 'Toate cele ${stations(total)} din $category sunt ascunse.';
  }
  return hidden == 1
      ? 'O stație din $category e ascunsă.'
      : '${stations(hidden)} din $category sunt ascunse.';
}

/// How many people listen to a station, in Romanian: "1 ascultător",
/// "23 de ascultători".
String listenersLabel(int count) =>
    romanianCount(count, one: 'ascultător', many: 'ascultători');

/// Categories the desktop row leaves out.
const desktopHiddenCategorySlugs = {'worship', 'gospel', 'colinde'};

/// Categories the desktop row starts with, in this order, right after
/// "Toate stațiile"; the others follow in the API's order.
const desktopLeadingCategorySlugs = [
  'general',
  'muzica',
  'copii',
  'emisiuni',
  'predici',
  'biblia',
];

/// [offer] as the desktop row shows it: without
/// [desktopHiddenCategorySlugs], and [desktopLeadingCategorySlugs] first.
StationGroupCategories desktopCategoryOffer(StationGroupCategories offer) {
  int rank(StationGroupCategory category) {
    final index = desktopLeadingCategorySlugs.indexOf(category.group.slug);
    return index < 0 ? desktopLeadingCategorySlugs.length : index;
  }

  final shown = [
    for (final category in offer.categories)
      if (!desktopHiddenCategorySlugs.contains(category.group.slug)) category,
  ];
  // Sorted with each category's place as the tie-break, so the others keep
  // the API's order.
  final ordered = [for (var i = 0; i < shown.length; i++) (i, shown[i])]
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return StationGroupCategories(
    categories: [for (final (_, category) in ordered) category],
    stationCount: offer.stationCount,
    listenerCount: offer.listenerCount,
  );
}
