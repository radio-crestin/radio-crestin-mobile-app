/// Media ids of the Android Auto browse tree.
///
/// Android Auto plays a browsed item by its media id alone (the item's
/// extras are not sent back), so the list a station was picked from is part
/// of the id: next/previous then stay within that list, as on CarPlay.
abstract final class AndroidAutoBrowseIds {
  /// The root tabs. The ids predate the tab names and stay as they are, so
  /// ids that Android Auto remembers keep working.
  static const favorites = 'favoriteStationsRootId';
  static const allStations = 'allStationsRootId';
  static const categories = 'categoriesRootId';

  static const _favoritesPrefix = 'favorites:';
  static const _groupPrefix = 'group:';

  /// The folder listing the stations of the category [slug].
  static String group(String slug) => '$_groupPrefix$slug';

  /// The category slug of a [group] folder id; null for any other id.
  static String? groupSlugOf(String folderId) {
    if (!folderId.startsWith(_groupPrefix)) return null;
    final slug = folderId.substring(_groupPrefix.length);
    return slug.isEmpty || slug.contains(':') ? null : slug;
  }

  /// A station of the Favorite tab; [stationMediaId] is its stream URL.
  static String favoriteItem(String stationMediaId) =>
      '$_favoritesPrefix$stationMediaId';

  /// A station of the category [slug]; [stationMediaId] is its stream URL.
  static String groupItem(String slug, String stationMediaId) =>
      '$_groupPrefix$slug:$stationMediaId';

  /// The station a browsed item plays and the list it was picked from.
  ///
  /// Ids without a known prefix (Toate stațiile, search results) are the
  /// station's own media id, picked from the whole catalog.
  static ({String stationMediaId, bool fromFavorites, String? fromGroup})
      parseItem(String id) {
    if (id.startsWith(_favoritesPrefix)) {
      return (
        stationMediaId: id.substring(_favoritesPrefix.length),
        fromFavorites: true,
        fromGroup: null,
      );
    }
    if (id.startsWith(_groupPrefix)) {
      // The slug ends at the first ':', as stream URLs hold ':' too.
      final rest = id.substring(_groupPrefix.length);
      final end = rest.indexOf(':');
      if (end > 0) {
        return (
          stationMediaId: rest.substring(end + 1),
          fromFavorites: false,
          fromGroup: rest.substring(0, end),
        );
      }
    }
    return (stationMediaId: id, fromFavorites: false, fromGroup: null);
  }
}
