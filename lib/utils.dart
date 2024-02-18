import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'globals.dart';

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
    return stationThumbnailUrl;
  }

  static List<String> getStationStreamUrls(Query$GetStations$stations? station) {
    if (station == null) {
      return [];
    }
    var streams = station.station_streams..sort((a, b) => a.order.compareTo(b.order));
    return streams.map((e) => e.stream_url.toString()).toList();
  }

  static Widget displayImage(String url, {String? fallbackImageUrl, bool cache = false}) {
    if (url.isEmpty) {
      return Icon(Icons.photo, color: Colors.red.shade100,); // Show an error icon if the URL is empty
    }

    return ExtendedImage.network(
      url,
      fit: BoxFit.cover,
      cache: cache,
      retries: 3,
      timeLimit: const Duration(seconds: 3),
      loadStateChanged: (ExtendedImageState state){
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            if (fallbackImageUrl?.isNotEmpty == true && fallbackImageUrl != url) {
              return ExtendedImage.network(
                fallbackImageUrl!,
                fit: BoxFit.cover,
                cache: true,
              ); // Use cached fallback image in case of an error
            }
            return Container(color: Colors.grey[300]);
          case LoadState.completed:
            var widget=ExtendedRawImage(
              image: state.extendedImageInfo?.image,
              fit: BoxFit.cover,
            );
            return widget;
          case LoadState.failed:
            developer.log("Error loading image, falling back");
            if (fallbackImageUrl?.isNotEmpty == true && fallbackImageUrl != url) {
              return ExtendedImage.network(
                  fallbackImageUrl!,
                  fit: BoxFit.cover,
                  cache: true,
              ); // Use cached fallback image in case of an error
            }
            return Icon(Icons.photo, color: Colors.red.shade100,);
        }
      },
    );
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
                    'Nu acum',
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
                    'Nu acum',
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
