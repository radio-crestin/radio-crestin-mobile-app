import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/utils/share_utils.dart';
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
      // If primary URL is empty but we have a fallback, use it
      if (fallbackImageUrl?.isNotEmpty == true) {
        return ExtendedImage.network(
          fallbackImageUrl!,
          fit: BoxFit.cover,
          cache: true,
        );
      }
      return Icon(Icons.photo, color: Colors.red.shade100,); // Show an error icon if no URLs available
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
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? reviewStatusJson = prefs.getString('_reviewStatus');
      
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
                  onPressed: () async {
                    // Track that user canceled the dialog
                    if (reviewStatusJson != null) {
                      Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson);
                      reviewStatus['last_rating_dialog_canceled'] = true;
                      reviewStatus['last_rating_dialog_canceled_at'] = DateTime.now().toIso8601String();
                      await prefs.setString('_reviewStatus', json.encode(reviewStatus));
                    }
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
            final theme = Theme.of(context);
            final isDarkMode = theme.brightness == Brightness.dark;
            
            return AlertDialog(
              title: Text(
                'Lasă-ne un review de 5 stele',
                style: TextStyle(
                  fontSize: 18,
                  color: theme.textTheme.titleLarge?.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              backgroundColor: isDarkMode ? const Color(0xff1e1e1e) : Colors.white,
              surfaceTintColor: Colors.transparent,
              content: Text(
                'Lasă-ne feedback dacă îți place\nRadio Creștin.',
                style: TextStyle(
                  color: theme.textTheme.bodyMedium?.color,
                ),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              actionsPadding: const EdgeInsets.only(bottom: 8, right: 8),
              actions: <Widget>[
                TextButton(
                  child: Text(
                    'Nu acum',
                    style: TextStyle(
                      color: isDarkMode 
                        ? const Color(0xffb3b3b3)  // Lighter gray for dark mode
                        : const Color(0xff757575),  // Medium gray for light mode
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onPressed: () async {
                    // Track that user canceled the dialog
                    if (reviewStatusJson != null) {
                      Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson);
                      reviewStatus['last_rating_dialog_canceled'] = true;
                      reviewStatus['last_rating_dialog_canceled_at'] = DateTime.now().toIso8601String();
                      await prefs.setString('_reviewStatus', json.encode(reviewStatus));
                    }
                    navigator.pop();
                  },
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xffe91e63).withOpacity(0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '5 stele ⭐',
                      style: TextStyle(
                        color: Color(0xffe91e63),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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

  static Future<void> incrementActionsMade({GraphQLClient? graphQLClient, String? currentStationName, String? currentStationSlug}) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? reviewStatusJson = prefs.getString('_reviewStatus');

      if (reviewStatusJson != null) {
        Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson);

        // Increment the actions_made counter
        reviewStatus['actions_made'] = (reviewStatus['actions_made'] ?? 0) + 1;
        int actionsMade = reviewStatus['actions_made'];

        // Save the updated preferences
        await prefs.setString('_reviewStatus', json.encode(reviewStatus));
        
        // Check if user has already completed 5-star review
        bool reviewCompleted = reviewStatus['review_completed'] == true;
        
        // Rating dialog intervals: 20, 100, 200, 400
        List<int> ratingIntervals = [20, 100, 200, 400];
        
        // Check rating dialog display conditions
        if (!reviewCompleted) {
          for (int interval in ratingIntervals) {
            if (actionsMade >= interval) {
              String prefKey = 'rating_dialog_shown_at_$interval';
              bool hasShownAtInterval = prefs.getBool(prefKey) ?? false;
              
              if (!hasShownAtInterval) {
                // Check if user canceled previous rating dialogs
                bool shouldShow = true;
                for (int prevInterval in ratingIntervals) {
                  if (prevInterval >= interval) break;
                  String prevPrefKey = 'rating_dialog_shown_at_$prevInterval';
                  bool prevShown = prefs.getBool(prevPrefKey) ?? false;
                  if (prevShown) {
                    // Dialog was shown at a previous interval, only show again if user didn't complete review
                    shouldShow = !reviewCompleted;
                    break;
                  }
                }
                
                if (shouldShow) {
                  await prefs.setBool(prefKey, true);
                  final navigator = navigatorKey.currentState;
                  if (navigator != null && navigator.mounted) {
                    Future.delayed(const Duration(seconds: 3), () {
                      Utils.show5StarReviewDialog();
                    });
                  }
                  break; // Only show one dialog at a time
                }
              }
            }
          }
        }
        
        // Share dialog intervals: 40, 150, 250, 600, 800, 1000
        List<int> shareIntervals = [40, 150, 250, 600, 800, 1000];
        
        // Check share dialog display conditions
        for (int interval in shareIntervals) {
          if (actionsMade >= interval) {
            String prefKey = 'share_dialog_shown_at_$interval';
            bool hasShownAtInterval = prefs.getBool(prefKey) ?? false;
            
            if (!hasShownAtInterval) {
              await prefs.setBool(prefKey, true);
              await _showShareDialog(prefs, graphQLClient, currentStationName, currentStationSlug);
              break; // Only show one dialog at a time
            }
          }
        }
      }
    } catch (e) {
      developer.log('Error incrementing actions_made: $e');
    }
  }

  static Future<void> _showShareDialog(
    SharedPreferences prefs,
    GraphQLClient? graphQLClient,
    String? currentStationName,
    String? currentStationSlug,
  ) async {
    try {
      if (graphQLClient == null) {
        return;
      }
      
      // Enable share promotion
      await prefs.setBool('show_share_promotion', true);
      
      // Get or create device ID
      String? deviceId = prefs.getString('device_id');
      if (deviceId == null) {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          deviceId = androidInfo.id;
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          deviceId = iosInfo.identifierForVendor;
        } else {
          deviceId = DateTime.now().millisecondsSinceEpoch.toString();
        }
        
        if (deviceId != null) {
          await prefs.setString('device_id', deviceId);
        }
      }
      
      if (deviceId != null) {
        final shareService = ShareService(graphQLClient);
        final shareLinkData = await shareService.getShareLink(deviceId);
        
        if (shareLinkData != null) {
          final shareUrl = shareLinkData.generateShareUrl(stationSlug: currentStationSlug);
          final shareMessage = ShareUtils.formatShareMessage(
            shareLinkData: shareLinkData,
            stationName: currentStationName,
            stationSlug: currentStationSlug,
          );
          
          // Show dialog after a small delay
          Future.delayed(const Duration(milliseconds: 500), () {
            final context = navigatorKey.currentContext;
            if (context != null) {
              ShareHandler.shareApp(
                context: context,
                shareUrl: shareUrl,
                shareMessage: shareMessage,
                stationName: currentStationName,
                shareLinkData: shareLinkData,
                showDialog: true,
              );
            }
          });
        }
      }
    } catch (e) {
      developer.log('Error showing share dialog: $e');
    }
  }
  
  static Future<void> resetDialogTracking() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      
      // Rating dialog intervals: 20, 100, 200, 400
      List<int> ratingIntervals = [20, 100, 200, 400];
      for (int interval in ratingIntervals) {
        await prefs.remove('rating_dialog_shown_at_$interval');
      }
      
      // Share dialog intervals: 40, 150, 250, 600, 800, 1000
      List<int> shareIntervals = [40, 150, 250, 600, 800, 1000];
      for (int interval in shareIntervals) {
        await prefs.remove('share_dialog_shown_at_$interval');
      }
      
      // Reset cancellation tracking
      String? reviewStatusJson = prefs.getString('_reviewStatus');
      if (reviewStatusJson != null) {
        Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson);
        reviewStatus.remove('last_rating_dialog_canceled');
        reviewStatus.remove('last_rating_dialog_canceled_at');
        await prefs.setString('_reviewStatus', json.encode(reviewStatus));
      }
    } catch (e) {
      developer.log('Error resetting dialog tracking: $e');
    }
  }
  
  static Future<Map<String, dynamic>> getDialogTrackingStatus() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      Map<String, dynamic> status = {};
      
      // Get review status
      String? reviewStatusJson = prefs.getString('_reviewStatus');
      if (reviewStatusJson != null) {
        Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson);
        status['review_completed'] = reviewStatus['review_completed'] ?? false;
        status['actions_made'] = reviewStatus['actions_made'] ?? 0;
        status['last_rating_dialog_canceled'] = reviewStatus['last_rating_dialog_canceled'] ?? false;
        status['last_rating_dialog_canceled_at'] = reviewStatus['last_rating_dialog_canceled_at'];
      }
      
      // Check which rating dialogs have been shown
      List<int> ratingIntervals = [20, 100, 200, 400];
      Map<int, bool> ratingDialogsShown = {};
      for (int interval in ratingIntervals) {
        ratingDialogsShown[interval] = prefs.getBool('rating_dialog_shown_at_$interval') ?? false;
      }
      status['rating_dialogs_shown'] = ratingDialogsShown;
      
      // Check which share dialogs have been shown
      List<int> shareIntervals = [40, 150, 250, 600, 800, 1000];
      Map<int, bool> shareDialogsShown = {};
      for (int interval in shareIntervals) {
        shareDialogsShown[interval] = prefs.getBool('share_dialog_shown_at_$interval') ?? false;
      }
      status['share_dialogs_shown'] = shareDialogsShown;
      
      return status;
    } catch (e) {
      developer.log('Error getting dialog tracking status: $e');
      return {};
    }
  }
}
