
import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';

import '../queries/getStations.graphql.dart';
import '../utils.dart';

class Station {
  Query$GetStations$stations rawStationData;
  Station({required this.rawStationData, required this.isFavorite});
  bool isFavorite = false;

  get id => rawStationData.id;
  get slug => rawStationData.slug;
  get title => rawStationData.title;
  get order => rawStationData.order;
  get stationStreams => rawStationData.station_streams;
  get totalListeners => rawStationData.total_listeners;
  String? get thumbnailUrl => rawStationData.thumbnail_url;
  String get displayTitle => rawStationData.title;
  String get displaySubtitle => Utils.getCurrentPlayedSongTitle(rawStationData);
  String get artist => Utils.getCurrentPlayedSongTitle(rawStationData);
  Uri get artUri => Uri.parse(Utils.getStationThumbnailUrl(rawStationData));
  bool get isUp => rawStationData.uptime?.is_up ?? false;
  int get songId => rawStationData.now_playing?.song?.id ?? -1;
  String get songTitle => rawStationData.now_playing?.song?.name ?? "";
  String get songArtist => rawStationData.now_playing?.song?.artist?.name ?? "";
  Widget get thumbnail => Utils.displayImage(
    Utils.getStationThumbnailUrl(rawStationData),
    fallbackImageUrl: rawStationData.thumbnail_url,
    cache: Utils.getStationThumbnailUrl(rawStationData) == rawStationData.thumbnail_url,
  );


  Future<MediaItem> get mediaItem async {
    return MediaItem(
      id: Utils.getStationStreamUrls(rawStationData).firstOrNull ?? "",
      title: rawStationData.title,
      displayTitle: displayTitle,
      displaySubtitle: displaySubtitle,
      artist: artist,
      duration: null,
      artUri: artUri,
      extras: {
        "station_id": rawStationData.id,
        "station_slug": rawStationData.slug,
        "station_title": rawStationData.title,
        "song_id": songId,
        "song_title": songTitle,
        "song_artist": songArtist,
        "total_listeners": rawStationData.total_listeners,
        "station_is_up": isUp,
        "station_thumbnail_url": rawStationData.thumbnail_url,
        "station_streams": Utils.getStationStreamUrls(rawStationData),
      },
    );
  }

}