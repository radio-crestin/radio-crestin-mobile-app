import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// The characters of a YouTube playlist ID; nothing else may reach the
/// player's script.
final _playlistId = RegExp(r'^[A-Za-z0-9_-]+$');

/// Whether [id] can be a YouTube playlist ID.
bool isYoutubePlaylistId(String id) => _playlistId.hasMatch(id);

extension YoutubePlaylistLoader on YoutubePlayerController {
  /// Loads the YouTube playlist [listId] and plays it from the start.
  ///
  /// youtube_player_iframe's `loadPlaylist` sends a single list as an array,
  /// which the IFrame API does not take as a playlist ID: the player stays
  /// blank. Its call is still made, as it waits until the player is ready;
  /// the list then loads again with the ID as a string, checked by
  /// [isYoutubePlaylistId] so it is safe inside the script.
  Future<void> loadPlaylistById(String listId) async {
    if (!isYoutubePlaylistId(listId)) {
      throw ArgumentError.value(listId, 'listId', 'not a YouTube playlist ID');
    }
    await loadPlaylist(list: [listId], listType: ListType.playlist);
    await webViewController.runJavaScript(
        "player.loadPlaylist({list: '$listId', listType: 'playlist'});");
  }
}
