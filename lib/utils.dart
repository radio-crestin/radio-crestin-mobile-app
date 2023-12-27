import 'dart:convert';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';

class Utils {
  static const _favoriteStationsKey = 'favoriteStationSlugs';

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

  // Function to check if a station is favorite
  static Future<bool> getStationIsFavorite(Query$GetStations$stations? station) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? favoriteJson = prefs.getString(_favoriteStationsKey);
    if (favoriteJson != null) {
      List<String> favorites = List<String>.from(json.decode(favoriteJson));
      return favorites.contains(station?.slug);
    }
    return false;
  }

  // Function to add or remove a station from favorites
  static Future<void> setStationIsFavorite(Query$GetStations$stations station, bool isFavorite) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? favoriteJson = prefs.getString(_favoriteStationsKey);
    List<String> favorites = favoriteJson != null ? List<String>.from(json.decode(favoriteJson)) : [];

    if (isFavorite) {
      // Add to favorites
      if (!favorites.contains(station.slug)) {
        favorites.add(station.slug);
      }
    } else {
      // Remove from favorites
      favorites.remove(station.slug);
    }

    developer.log("set_favoriteJson: ${json.encode(favorites)}");
    // Save the updated list back to preferences
    await prefs.setString(_favoriteStationsKey, json.encode(favorites));
  }

  static Future<MediaItem> getStationMetadata(Query$GetStations$stations? station) async {
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
        "station_thumbnail_url": station?.thumbnail_url,
        "station_streams": Utils.getStationStreamUrls(station),
        "is_favorite": await Utils.getStationIsFavorite(station)? "true": "false",
      },
    );
  }

  static displayImage(String url, {String? fallbackImageUrl, bool cache = false}) {
    if (url == "") {
      return null;
    }
    if (cache) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        errorWidget: (context, exception, stacktrace) {
          developer.log("Error loading image: $exception");
          return Container(
            color: Colors.red[100],
          );
        },
        placeholder: (context, progress) {
          if(fallbackImageUrl != null) {
            return displayImage(fallbackImageUrl, cache: true);
          }
          return Container(
            color: Colors.grey[300],
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
