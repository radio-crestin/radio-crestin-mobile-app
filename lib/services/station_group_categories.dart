import '../queries/getStations.graphql.dart';
import '../types/Station.dart';

/// A station group as the filter sheet offers it.
class StationGroupCategory {
  const StationGroupCategory({required this.group, required this.stationCount});

  final Query$GetStations$station_groups group;

  /// How many of the app's stations the group holds.
  final int stationCount;
}

/// What the station filter sheet offers: every station, then the categories.
class StationGroupCategories {
  const StationGroupCategories({
    required this.categories,
    required this.stationCount,
    required this.listenerCount,
  });

  /// The categories, in the API's order.
  final List<StationGroupCategory> categories;

  /// How many stations "Toate stațiile" holds.
  final int stationCount;

  /// How many people listen right now, across every station.
  final int listenerCount;

  /// Builds the offer from the API's [groups] and the app's [stations].
  ///
  /// Categories follow the groups' `order`; equal orders keep the API's
  /// sequence. As in the car's Categories grid (`CarCategoryLayout`), a group
  /// with none of [stations] is dropped, and so is a group holding every
  /// grouped station (the API's "all" group), since "Toate stațiile" already
  /// offers it. Private stations belong to no group, so they don't count.
  factory StationGroupCategories.compute({
    required List<Query$GetStations$station_groups> groups,
    required List<Station> stations,
  }) {
    final known = {for (final s in stations) s.id as int};
    final indexed = [for (var i = 0; i < groups.length; i++) (i, groups[i])]
      ..sort((a, b) {
        final byOrder = a.$2.order.compareTo(b.$2.order);
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
    final idsByGroup = [
      for (final (_, group) in indexed)
        (
          group,
          {
            for (final link in group.station_to_station_groups)
              if (known.contains(link.station_id)) link.station_id,
          },
        ),
    ];
    final grouped = {for (final (_, ids) in idsByGroup) ...ids};
    return StationGroupCategories(
      categories: [
        for (final (group, ids) in idsByGroup)
          if (ids.isNotEmpty && ids.length != grouped.length)
            StationGroupCategory(group: group, stationCount: ids.length),
      ],
      stationCount: stations.length,
      listenerCount: stations.fold(
        0,
        (sum, s) => sum + ((s.totalListeners as int?) ?? 0),
      ),
    );
  }

  /// Whether the group with [groupId] is one of the [categories]. A group
  /// the sheet hides, like the API's "all" group, filters nothing visible,
  /// so the sheet shows "Toate stațiile" as chosen instead.
  bool offers(int? groupId) =>
      groupId != null && categories.any((c) => c.group.id == groupId);
}
