import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:path_provider/path_provider.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'globals.dart';
import 'seek_mode_manager.dart';
import 'services/network_service.dart';

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

  /// Returns the thumbnail URL for a station.
  /// In data saving modes (unstable connection or mobile data), always returns
  /// the station's own thumbnail (cached on disk) instead of downloading song thumbnails.
  static String getStationThumbnailUrl(Query$GetStations$stations? station) {
    if (station == null) {
      return "";
    }
    String stationThumbnailUrl = station.thumbnail_url ?? CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL;
    final isDataSaving = SeekModeManager.isUnstableConnection ||
        SeekModeManager.isCarConnected ||
        NetworkService.instance.isOnMobileData.value;
    if (!isDataSaving && station.now_playing?.song?.thumbnail_url != null) {
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

  static List<Map<String, String>> getStationStreamObjects(Query$GetStations$stations? station) {
    if (station == null) {
      return [];
    }
    var streams = station.station_streams..sort((a, b) => a.order.compareTo(b.order));
    return streams.map((e) => {"url": e.stream_url, "type": e.type}).toList();
  }

  /// Returns the station slug a deep link points to, or `''` when it names
  /// no station.
  ///
  /// Web links (share links, NFC tags) carry the slug as the first path
  /// segment and often a query string (`?s=…`, `?ref=nfc`) that must not
  /// leak into it. The custom `radiocrestin://<slug>` scheme carries the
  /// slug as the host.
  static String stationSlugFromUri(Uri uri) {
    final firstSegment = uri.pathSegments
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    if (uri.scheme == 'http' || uri.scheme == 'https') return firstSegment;
    return uri.host.isNotEmpty ? uri.host : firstSegment;
  }

  /// Branded placeholder shown when a station image is missing or fails to load
  /// (offline / 404 / 403, e.g. Radio SOS). Renders the app logo centered on a
  /// soft neutral background, padded so it sits nicely inside thumbnails of any
  /// size — replaces the old broken-photo icon.
  static Widget _logoPlaceholder() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final pad = side.isFinite && side > 0 ? side * 0.2 : 10.0;
        return ColoredBox(
          color: const Color(0xFFF2F2F2),
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: Image.asset(
              'assets/icons/ic_logo_filled.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
        );
      },
    );
  }

  static Widget displayImage(String url, {String? fallbackImageUrl, bool cache = false, String? cachedFilePath, int? cacheWidth, Duration? cacheMaxAge}) {
    cacheWidth ??= 210;
    if (url.isEmpty && cachedFilePath == null) {
      return _logoPlaceholder();
    }

    // When URL is available, always use network with caching to avoid
    // widget-type switches (network → file) that cause grey flash flicker.
    // ExtendedImage.network with cache:true uses its own memory + disk cache.
    if (url.isNotEmpty) {
      return _networkImage(url, fallbackImageUrl: fallbackImageUrl, cache: cache, cacheWidth: cacheWidth, cacheMaxAge: cacheMaxAge);
    }

    // Fallback to local cached file only when URL is unavailable (offline)
    if (cachedFilePath != null) {
      return ExtendedImage.file(
        File(cachedFilePath),
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        // Keep the previous picture on screen until the new one decodes, so
        // a source change never flashes the grey loading square.
        gaplessPlayback: true,
        loadStateChanged: (ExtendedImageState state) {
          switch (state.extendedImageLoadState) {
            case LoadState.loading:
              return Container(color: Colors.grey[300]);
            case LoadState.completed:
              return null;
            case LoadState.failed:
              return _logoPlaceholder();
          }
        },
      );
    }

    return _logoPlaceholder();
  }

  static Widget _networkImage(String url, {String? fallbackImageUrl, bool cache = false, int? cacheWidth, Duration? cacheMaxAge}) {
    cacheWidth ??= 210;
    if (url.isEmpty) {
      return _logoPlaceholder();
    }

    return ExtendedImage.network(
      url,
      fit: BoxFit.cover,
      cache: cache,
      retries: 3,
      timeLimit: const Duration(seconds: 3),
      cacheWidth: cacheWidth,
      cacheMaxAge: cacheMaxAge,
      // The URL changes with every song (current artwork), and the same
      // element is reused, so without this each song change blanks the
      // thumbnail to grey until the new artwork downloads.
      gaplessPlayback: true,
      loadStateChanged: (ExtendedImageState state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return Container(color: Colors.grey[300]);
          case LoadState.completed:
            return null;
          case LoadState.failed:
            if (fallbackImageUrl?.isNotEmpty == true && fallbackImageUrl != url) {
              return ExtendedImage.network(
                fallbackImageUrl!,
                fit: BoxFit.cover,
                cache: true,
                cacheWidth: cacheWidth,
              );
            }
            return _logoPlaceholder();
        }
      },
    );
  }

  /// URLs under which `Station.displayThumbnail` disk-caches station logos.
  static Set<String> stationLogoUrls(
    Iterable<Query$GetStations$stations> stations,
  ) {
    final prefix = CONSTANTS.IMAGE_PROXY_PREFIX;
    final urls = <String>{};
    for (final station in stations) {
      final logo =
          station.thumbnail_url ?? CONSTANTS.DEFAULT_STATION_THUMBNAIL_URL;
      // Proxied as the primary URL, unproxied as the fallback URL.
      urls.add(logo);
      if (prefix.isNotEmpty) urls.add('$prefix$logo');
    }
    return urls;
  }

  /// Deletes images that `ExtendedImage.network(cache: true)` wrote to disk
  /// more than [maxAge] ago, except those cached for [keepUrls].
  ///
  /// extended_image enforces `cacheMaxAge` only when the same URL is asked
  /// for again. Song-art URLs rarely are, so their files would pile up for
  /// as long as the app is installed. Station logos must be kept: they have
  /// no max age, and once decoded they are served from the memory cache, so
  /// a deleted logo is not written back this session and the next offline
  /// launch would show the placeholder instead.
  static Future<void> pruneImageDiskCache({
    required Iterable<String> keepUrls,
    Duration maxAge = const Duration(days: 7),
  }) async {
    if (kIsWeb) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final dirPath =
          '${tempDir.path}${Platform.pathSeparator}$cacheImageFolderName';
      final keepNames = keepUrls.map(keyToMd5).toSet();
      final cutoff = DateTime.now().subtract(maxAge);
      // A long-lived install can hold thousands of files: stat and delete
      // them off the UI isolate so the scan never costs frames.
      final deleted = await compute(
        _deleteStaleCacheFilesEntry,
        (dirPath, cutoff, keepNames),
      );
      developer.log('Image disk cache: pruned $deleted file(s)');
    } catch (e) {
      developer.log('Image disk cache prune failed: $e');
    }
  }

  static int _deleteStaleCacheFilesEntry(
    (String, DateTime, Set<String>) args,
  ) =>
      deleteStaleCacheFiles(args.$1, args.$2, args.$3);

  /// Deletes the files directly inside [dirPath] last written before
  /// [cutoff], except those named in [keepNames], and returns how many were
  /// deleted.
  @visibleForTesting
  static int deleteStaleCacheFiles(
    String dirPath,
    DateTime cutoff,
    Set<String> keepNames,
  ) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return 0;
    var deleted = 0;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      if (keepNames.contains(entity.uri.pathSegments.last)) continue;
      try {
        if (entity.statSync().modified.isBefore(cutoff)) {
          entity.deleteSync();
          deleted++;
        }
      } on FileSystemException {
        // The OS can purge the cache folder mid-scan; skip that file.
      }
    }
    return deleted;
  }

  static Future<void> requestReviewAndUpdateStatus(BuildContext dialogContext) async {
    final InAppReview inAppReview = InAppReview.instance;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String? reviewStatusJson = prefs.getString('_reviewStatus');
    Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson!);

    if (await inAppReview.isAvailable()) {
      await inAppReview.requestReview();
      reviewStatus['review_completed'] = true;
      await prefs.setString('_reviewStatus', json.encode(reviewStatus));
    }
    if (dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
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
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                CupertinoDialogAction(
                  child: const Text(
                    '5 stele',
                    style: TextStyle(color: Colors.blue),
                  ),
                  onPressed: () async {
                    await requestReviewAndUpdateStatus(context);
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
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xffe91e63).withValues(alpha: 0.1),
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
                    await requestReviewAndUpdateStatus(context);
                  },
                ),
              ],
            );
          }
        },
      );
    }
  }

  static Future<void> incrementActionsMade({GraphQLClient? graphQLClient, String? currentStationName}) async {
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
        
        // Share dialog disabled
      }
    } catch (e) {
      developer.log('Error incrementing actions_made: $e');
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
