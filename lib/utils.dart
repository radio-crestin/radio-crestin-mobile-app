import 'package:audio_service/audio_service.dart';
import 'package:fast_cached_network_image/fast_cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'dart:developer' as developer;

import 'constants.dart';

class Utils {
  static String getCurrentPlayedSongTitle(Query$GetStations$stations? station) {
    if (station == null) {
      return "";
    }
    String currentSongTitle = "";
    if (station.now_playing?.song?.name != null &&
        station.now_playing?.song?.name != "") {
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
    String stationThumbnailUrl =
        station.thumbnail_url ?? CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL;
    if (station.now_playing?.song?.thumbnail_url != null) {
      stationThumbnailUrl = station.now_playing?.song?.thumbnail_url ?? "";
    }
    if (CONSTANTS.IMAGE_PROXY_PREFIX != "") {
      stationThumbnailUrl =
          "${CONSTANTS.IMAGE_PROXY_PREFIX}$stationThumbnailUrl";
    }
    if (kDebugMode) {
      stationThumbnailUrl = "https://corsproxy.io/$stationThumbnailUrl";
    }
    return stationThumbnailUrl;
  }

  static String getStationStreamUrl(Query$GetStations$stations? station) {
    return station?.proxy_stream_url ?? station?.stream_url ?? "";
  }

  static MediaItem getStationMetadata(Query$GetStations$stations? station) {
    return MediaItem(
      id: getStationStreamUrl(station) ?? "",
      title: station?.title.toString() ?? "",
      displayTitle: station?.title.toString(),
      displaySubtitle: Utils.getCurrentPlayedSongTitle(station),
      artist: Utils.getCurrentPlayedSongTitle(station),
      artUri: Uri.parse(Utils.getStationThumbnailUrl(station)),
    );
  }

  static displayImage(String url, {bool cache = false}) {
    if (cache) {
      return FastCachedImage(
        url: url,
        fit: BoxFit.cover,
        gaplessPlayback: true,
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
        gaplessPlayback: true,
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
