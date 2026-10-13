import '../appAudioHandler.dart';
import '../types/Station.dart';
import 'playlist_controller.dart';

/// Retries [station] at once: the station error's "Reîncearcă".
///
/// That is `AppAudioHandler.playStation`, which starts the station's
/// connection cycle over, with no backoff. It skips the two cases the
/// error leaves behind, which are handled first:
/// - after a failed pass over every stream the retry loop keeps cycling
///   with backoff, and `playStation` skips the station it is still
///   connecting to;
/// - a playlist whose items all failed stays active (only its playback
///   stops), and `playStation` skips an active playlist.
Future<void> retryStation(
  Station station, {
  required AppAudioHandler handler,
  required PlaylistController playlist,
}) async {
  if (station.isPlaylist &&
      handler.isPlaylistMode &&
      playlist.activeStation?.id == station.id) {
    // What `playStation` runs for a playlist, once past its skip.
    return playlist.startPlaylist(station);
  }
  if (!station.isPlaylist &&
      handler.currentStation.valueOrNull?.id == station.id &&
      handler.isPlayingOrConnecting) {
    // Ends the retry loop. Not `play()` instead: the loop it supersedes
    // exits after the new one starts and clears its connecting state, so
    // the mini player could show play and a failed retry would go unseen.
    await handler.pause();
  }
  await handler.playStation(station);
}
