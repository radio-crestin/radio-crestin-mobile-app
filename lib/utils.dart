import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'globals.dart';

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
    List<String> favorites =
        favoriteJson != null ? List<String>.from(json.decode(favoriteJson)) : [];

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
        "is_favorite": await Utils.getStationIsFavorite(station) ? "true" : "false",
      },
    );
  }

  static Widget displayImage(String url, {String? fallbackImageUrl, bool cache = false}) {
    if (url.isEmpty) {
      return Icon(Icons.error); // Show an error icon if the URL is empty
    }

    Widget loadImage(String imageUrl) {
      return CachedNetworkImage(
        imageUrl: imageUrl,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        errorWidget: (context, exception, stacktrace) {
          developer.log("Error loading image: $exception");
          return Icon(Icons.error); // Default error widget in case of an error
        },
        placeholder: (context, url) =>
            Container(color: Colors.grey[300]), // Placeholder while loading
      );
    }

    if (cache) {
      return loadImage(url);
    } else {
      return Image.network(
        url,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, exception, stacktrace) {
          developer.log("Error loading image: $exception");
          if (fallbackImageUrl?.isNotEmpty == true) {
            return loadImage(fallbackImageUrl!); // Use cached fallback image in case of an error
          }
          return Icon(Icons.error); // Fallback to error icon if no fallback image is provided
        },
        frameBuilder:
            (BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) {
          return child;
        },
      );
    }
  }

  static Future<void> requestReviewAndUpdateStatus(NavigatorState navigator) async {
    final InAppReview inAppReview = InAppReview.instance;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String? reviewStatusJson = prefs.getString('_reviewStatus');
    Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson!);

    if (await inAppReview.isAvailable()) {
      inAppReview.requestReview();
      reviewStatus['review_completed'] = true;
      await prefs.setString('_reviewStatus', json.encode(reviewStatus));
    }
    navigator.pop();
  }

  static Future<void> show5StarReviewDialog() async {
    final navigator = navigatorKey.currentState;
    if (navigator != null && navigator.mounted) {
      return showDialog(
        context: navigator.context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          if (Platform.isIOS) {
            // CupertinoAlertDialog for iOS
            return CupertinoAlertDialog(
              title: const Text('Lasă-ne un review de 5 stele'),
              content: const Text('Lasă-ne feedback dacă îți place\nRadio Creștin.'),
              actions: <Widget>[
                CupertinoDialogAction(
                  child: const Text(
                    'Anulează',
                    style: TextStyle(color: Colors.blue),
                  ),
                  onPressed: () {
                    navigator.pop();
                  },
                ),
                CupertinoDialogAction(
                  child: const Text(
                    '5 stele',
                    style: TextStyle(color: Colors.blue),
                  ),
                  onPressed: () async {
                    await requestReviewAndUpdateStatus(navigator);
                  },
                ),
              ],
            );
          } else {
            // AlertDialog for Android
            return AlertDialog(
              title: const Text(
                'Lasă-ne un review de 5 stele',
                style: TextStyle(fontSize: 18),
              ),
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              content: const Text('Lasă-ne feedback dacă îți place\nRadio Creștin.'),
              actions: <Widget>[
                TextButton(
                  child: const Text(
                    'Anulează',
                    style: TextStyle(color: Colors.blue),
                  ),
                  onPressed: () {
                    navigator.pop();
                  },
                ),
                TextButton(
                  child: const Text(
                    '5 stele',
                    style: TextStyle(color: Colors.blue),
                  ),
                  onPressed: () async {
                    await requestReviewAndUpdateStatus(navigator);
                  },
                ),
              ],
            );
          }
        },
      );
    }
  }

  static Future<void> incrementActionsMade() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? reviewStatusJson = prefs.getString('_reviewStatus');

      if (reviewStatusJson != null) {
        Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson);

        if (reviewStatus['review_completed'] == true) {
          return;
        }

        // Increment the actions_made counter
        reviewStatus['actions_made'] = (reviewStatus['actions_made'] ?? 0) + 1;

        // Save the updated preferences
        await prefs.setString('_reviewStatus', json.encode(reviewStatus));
        switch (reviewStatus['actions_made']) {
          case 20:
          case 80:
          case 200:
          case 1000:
          case 5000:
          case 10000:
          case 20000:
            final navigator = navigatorKey.currentState;
            if (navigator != null && navigator.mounted) {
              Future.delayed(const Duration(seconds: 3), () {
                Utils.show5StarReviewDialog();
              });
            }
            break;
          default:
            break;
        }
      }
    } catch (e) {
      developer.log('Error incrementing actions_made: $e');
    }
  }
}
