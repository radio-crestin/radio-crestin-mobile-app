import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:fast_cached_network_image/fast_cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';

import 'constants.dart';

class Utils {
  static String getCurrentPlayedSongTitle(Query$GetStations$stations? station) {
    if (station == null) {
      return "";
    }
    String currentSongTitle = "";
    if (station.now_playing?.song?.name != null && station.now_playing?.song?.name != "") {
      currentSongTitle += station.now_playing?.song?.name ?? '';
    }
    if (station.now_playing?.song?.artist?.name != null &&
        station.now_playing?.song?.artist?.name != "") {
      currentSongTitle += " • ${station.now_playing?.song?.artist?.name}";
    }
    return currentSongTitle;
  }

  static String getStationThumbnailUrl(Query$GetStations$stations? station) {
    if (station == null) {
      return "";
    }
    String stationThumbnailUrl = station.thumbnail_url ?? CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL;
    if (station.now_playing?.song?.thumbnail_url != null) {
      stationThumbnailUrl = station.now_playing?.song?.thumbnail_url ?? "";
    }
    if (CONSTANTS.IMAGE_PROXY_PREFIX != "") {
      stationThumbnailUrl = "${CONSTANTS.IMAGE_PROXY_PREFIX}$stationThumbnailUrl";
    }
    try{
      stationThumbnailUrl = Uri.parse(stationThumbnailUrl).replace(queryParameters: CONSTANTS.IMAGE_PROXY_QUERY_PARAMETERS).toString();
    } catch(e) {
      developer.log("Error setting IMAGE_PROXY_QUERY_PARAMETERS: $e");
    }
    return stationThumbnailUrl;
  }

  static List<String> getStationStreamUrls(Query$GetStations$stations? station) {
    List<String> availableStreamUrls = [];
    if (station == null) {
      return availableStreamUrls;
    }
    if (station.hls_stream_url != null && station.hls_stream_url != "") {
      availableStreamUrls.add(station.hls_stream_url!);
    }
    if (station.proxy_stream_url != null && station.proxy_stream_url != "") {
      availableStreamUrls.add(station.proxy_stream_url!);
    }
    if (station.stream_url != "") {
      availableStreamUrls.add(station.stream_url);
    }
    return availableStreamUrls;
  }

  static MediaItem getStationMetadata(Query$GetStations$stations? station) {
    return MediaItem(
      // id: station?.id.toString() ?? "0",
      id: getStationStreamUrls(station).first,
      title: station?.title.toString() ?? "",
      displayTitle: station?.title.toString(),
      displaySubtitle: Utils.getCurrentPlayedSongTitle(station),
      artist: Utils.getCurrentPlayedSongTitle(station),
      duration: null,
      artUri: Uri.parse(Utils.getStationThumbnailUrl(station)),
      extras: {
        "station_id": station?.id,
        "station_slug": station?.slug,
        "station_title": station?.title,
        "song_id": station?.now_playing?.song?.id ?? -1,
        "song_title": station?.now_playing?.song?.name ?? "",
        "song_artist": station?.now_playing?.song?.artist?.name ?? "",
        "total_listeners": station?.total_listeners,
        "station_is_up": station?.uptime?.is_up,
        "thumbnail_url": station?.thumbnail_url,
        "station_streams": Utils.getStationStreamUrls(station),
      },
    );
  }

  static displayImage(String url, {bool cache = false}) {
    if (url == "") {
      return null;
    }
    if (cache) {
      return FastCachedImage(
        url: url,
        fit: BoxFit.cover,
        gaplessPlayback: false,
        fadeInDuration: Duration.zero,
        errorBuilder: (context, exception, stacktrace) {
          developer.log("Error loading image: $exception");
          return Container(
            color: Colors.white,
          );
        },
        loadingBuilder: (context, progress) {
          return Container(
            color: Colors.white,
          );
        },
      );
    } else {
      return Image.network(
        url,
        fit: BoxFit.cover,
        gaplessPlayback: false,
        errorBuilder: (context, exception, stacktrace) {
          developer.log("Error loading image: $exception");
          return Container(
            color: Colors.white,
          );
        },
      );
    }
  }
}
