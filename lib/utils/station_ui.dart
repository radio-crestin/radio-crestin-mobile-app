import '../types/Station.dart';
import '../types/playlist_item.dart';

/// Localized subtitle line for a station wherever it is listed or shown in a
/// player (station list rows, mini player, full player and the CarPlay /
/// Android Auto lists).
///
/// Stations without a now-playing song must never render a blank/broken line:
///   - `playlist` → the current item's title when one is playing, otherwise a
///     "Listă de redare" label (with the item count appended when
///     [playlistItemCount] > 0).
///   - `tv` → the now-playing song line when present; otherwise a
///     "Transmisiune live" label, but only when [tvLiveFallback] is set (the
///     car keeps its historical "song line or nothing" behavior).
///   - `radio` → the now-playing song line, or null when idle (blank, as
///     before).
///
/// Pure and side-effect free so it is trivially unit-testable and can back
/// every surface from one place.
String? computeStationSubtitle({
  required StationMediaType type,
  required String songLine,
  required bool isRomanian,
  String? playlistItemTitle,
  int playlistItemCount = 0,
  bool tvLiveFallback = false,
}) {
  switch (type) {
    case StationMediaType.playlist:
      final itemTitle = playlistItemTitle?.trim() ?? '';
      if (itemTitle.isNotEmpty) return itemTitle;
      final base = isRomanian ? 'Listă de redare' : 'Playlist';
      if (playlistItemCount > 0) {
        final noun = isRomanian
            ? (playlistItemCount == 1 ? 'element' : 'elemente')
            : (playlistItemCount == 1 ? 'item' : 'items');
        return '$base · $playlistItemCount $noun';
      }
      return base;
    case StationMediaType.tv:
      if (songLine.isNotEmpty) return songLine;
      if (tvLiveFallback) {
        return isRomanian ? 'Transmisiune live' : 'Live broadcast';
      }
      return null;
    case StationMediaType.radio:
      return songLine.isNotEmpty ? songLine : null;
  }
}

/// Whether tapping [station] in the station list should auto-open the full
/// player (so its video is immediately visible), instead of only surfacing the
/// mini player.
///
/// True for live TV channels and for playlist stations whose first *playable*
/// item is a video. Radio and audio-first playlists keep the mini-player-only
/// behavior. Pure so the decision is unit-testable.
bool stationOpensFullPlayerOnTap(Station station) {
  if (station.isTv) return true;
  if (station.isPlaylist) return _firstPlayableIsVideo(station.playlistItems);
  return false;
}

/// Returns true when the first playable playlist entry is a video. Items of an
/// unrecognized ([PlaylistItemType.unknown]) kind are never playable, so they
/// are skipped; the first recognized entry decides.
bool _firstPlayableIsVideo(List<PlaylistItem> items) {
  for (final item in items) {
    if (item.type == PlaylistItemType.unknown) continue;
    return item.type == PlaylistItemType.video;
  }
  return false;
}
