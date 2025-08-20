import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:like_button/like_button.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:radio_crestin/utils/vibration_pattern.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../appAudioHandler.dart';
import '../types/Station.dart';
import '../utils/screen_utils.dart';

class FullAudioPlayer extends StatefulWidget {
  final AppAudioHandler audioHandler;
  final CustomPanelController slidingUpPanelController;

  const FullAudioPlayer({
    super.key,
    required this.audioHandler,
    required this.slidingUpPanelController,
  });

  @override
  _FullAudioPlayerState createState() => _FullAudioPlayerState();
}

class _FullAudioPlayerState extends State<FullAudioPlayer> {
  Timer? sleepTimer;
  bool isTimerActive = false;
  Station? currentStation;
  final PageController pageController = PageController();
  final List _subscriptions = [];

  List<Station> filteredStationsIncludingCurrentStation = [];

  @override
  void initState() {
    super.initState();
    _subscriptions
        .add(widget.audioHandler.filteredStations.stream.listen((List<Station> filteredStations) {
      setState(() {
        filteredStationsIncludingCurrentStation = [
          if (currentStation != null && !filteredStations.contains(currentStation)) currentStation!,
          ...filteredStations,
        ];
      });

      final newPageIndex = filteredStationsIncludingCurrentStation
          .indexWhere((item) => item.id == currentStation?.id);
      if (pageController.page != null) {
        pageController.jumpToPage(newPageIndex);
      }
    }));

    _subscriptions.add(widget.audioHandler.currentStation.stream.listen((Station? value) {
      setState(() {
        currentStation = value;
      });

      final newPageIndex = filteredStationsIncludingCurrentStation
          .indexWhere((item) => item.id == currentStation?.id);
      if (pageController.page != null) {
        pageController
            .animateToPage(
          newPageIndex,
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
        )
            .then((_) {
        });
      }
    }));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasYoutubeLink = (currentStation != null &&
        (currentStation!.songArtist.isNotEmpty || currentStation!.songTitle.isNotEmpty));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16.0),
          topRight: Radius.circular(16.0),
        ),
      ),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  margin: const EdgeInsets.only(top: 3.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            borderRadius: const BorderRadius.all(Radius.circular(12.0))),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 17.0),
            Text(
              currentStation?.displayTitle ?? "",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: ScreenUtils.isSmallDevice(context) ? 18 : 20,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: ScreenUtils.isSmallDevice(context) ? 12.0 : 18.0),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: (details) {
                // Detect swipe direction
                if (details.primaryVelocity! > 0) {
                  // Swipe right
                  widget.audioHandler.skipToPrevious();
                } else if (details.primaryVelocity! < 0) {
                  // Swipe left
                  widget.audioHandler.skipToNext();
                }
              },
              child: SizedBox(
                width: ScreenUtils.isSmallDevice(context) ? 240.0 : 270.0,
                height: ScreenUtils.isSmallDevice(context) ? 240.0 : 270.0,
                child: PageView.builder(
                  // physics: const AlwaysScrollableScrollPhysics(),
                  physics: const NeverScrollableScrollPhysics(),
                  controller: pageController,
                  scrollDirection: Axis.horizontal,
                  itemCount: filteredStationsIncludingCurrentStation.length,
                  itemBuilder: (BuildContext context, int itemIdx) {
                    final station = filteredStationsIncludingCurrentStation[itemIdx];

                    return Container(
                      width: ScreenUtils.isSmallDevice(context) ? 230.0 : 260.0,
                      height: ScreenUtils.isSmallDevice(context) ? 230.0 : 260.0,
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: const BorderRadius.all(Radius.circular(8)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withOpacity(0.35),
                            spreadRadius: 0,
                            blurRadius: 4,
                            offset: const Offset(2, 3),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.all(Radius.circular(8)),
                        child: station.thumbnail,
                      ),
                    );
                  },
                ),
              ),
            ),
            SizedBox(height: ScreenUtils.isSmallDevice(context) ? 12.0 : 18.0),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                currentStation?.songTitle ?? "Metadate indisponibile",
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: ScreenUtils.isSmallDevice(context) ? 19 : 21,
                ),
              ),
            ),
            Text(
              currentStation?.songArtist ?? "",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                InkWell(
                  onTap: widget.audioHandler.skipToPrevious,
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Icon(
                      Icons.skip_previous,
                      size: 34,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                SizedBox(width: ScreenUtils.isSmallDevice(context) ? 16.0 : 24.0),
                StreamBuilder<PlaybackState>(
                  stream: widget.audioHandler.playbackState.distinct(),
                  builder: (context, snapshot) {
                    final playbackState = snapshot.data;
                    final processingState = playbackState?.processingState;
                    final playing = playbackState?.playing ?? true;
                    final buffering = processingState == AudioProcessingState.loading ||
                        processingState == AudioProcessingState.buffering;
                    if (buffering) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          ClipOval(
                            child: Material(
                              color: Theme.of(context).bottomAppBarTheme.color,
                              child: const SizedBox(width: 62, height: 62,),
                            ),
                          ),
                          CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).colorScheme.onPrimary,
                            ),
                          )
                        ],
                      );
                    }

                    return Stack(
                      children: [
                        ClipOval(
                          child: Material(
                              color: Theme.of(context).bottomAppBarTheme.color,
                              child: IconButton(
                                icon: (playing
                                    ? Icon(Icons.pause_rounded, color: Theme.of(context).colorScheme.onPrimary)
                                    : Icon(Icons.play_arrow_rounded, color: Theme.of(context).colorScheme.onPrimary)),
                                iconSize: 46,
                                onPressed: () {
                                  VibrationPattern.lightImpact();
                                  playing ? widget.audioHandler.pause() : widget.audioHandler.play();
                                },
                              )),
                        ),
                      ],
                    );
                  },
                ),
                SizedBox(width: ScreenUtils.isSmallDevice(context) ? 16.0 : 24.0),
                InkWell(
                  onTap: widget.audioHandler.skipToNext,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Icon(
                      Icons.skip_next_rounded,
                      size: 34,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: ScreenUtils.isSmallDevice(context) ? 50.0 : 90.0),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                InkWell(
                  customBorder: CircleBorder(),
                  onTap: () {
                    showSleepTimerDialog(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      children: [
                        Icon(
                          Icons.nights_stay_sharp,
                          color: isTimerActive ? Theme.of(context).primaryColor : Theme.of(context).colorScheme.onSurface,
                          size: 24,
                        ),
                        Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text(
                            'somn',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    isTimerActive ? Theme.of(context).primaryColor : Theme.of(context).colorScheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  customBorder: const CircleBorder(),
                  child: Container(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      children: [
                        LikeButton(
                          size: 25,
                          isLiked: currentStation?.isFavorite ?? false,
                          likeBuilder: (bool isLiked) {
                            return Icon(
                              isLiked ? Icons.favorite_sharp : Icons.favorite_border_sharp,
                              color: isLiked ? Theme.of(context).primaryColor : Theme.of(context).colorScheme.onSurface,
                              size: 23,
                            );
                          },
                          onTap: (bool isLiked) async {
                            if (currentStation != null) {
                              widget.audioHandler.setStationIsFavorite(currentStation!, !isLiked);
                            }
                            return !isLiked;
                          },
                        ),
                        Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text('favorit', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () async {
                      if (!hasYoutubeLink) {
                        return;
                      }
                      if (currentStation != null) {
                        final query =
                            "${currentStation?.songArtist} - ${currentStation?.songTitle}";
                        final encodedQuery = Uri.encodeQueryComponent(query);

                        final searchUrl = 'https://www.youtube.com/results?q=$encodedQuery';

                        if (!await launchUrl(Uri.parse(searchUrl))) {
                          Fluttertoast.showToast(
                              msg: "A apărut o eroare neașteptată în lansarea YouTube.",
                              toastLength: Toast.LENGTH_SHORT,
                              gravity: ToastGravity.BOTTOM,
                              timeInSecForIosWeb: 1,
                              backgroundColor: Theme.of(context).colorScheme.onSurface,
                              textColor: Theme.of(context).colorScheme.surface,
                              fontSize: 16.0);
                        }
                      } else {
                        Fluttertoast.showToast(
                            msg: "Vă rugam să alegeți o statie de radio.",
                            toastLength: Toast.LENGTH_SHORT,
                            gravity: ToastGravity.BOTTOM,
                            timeInSecForIosWeb: 1,
                            backgroundColor: Theme.of(context).colorScheme.onSurface,
                            textColor: Theme.of(context).colorScheme.surface,
                            fontSize: 16.0);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10.0),
                      child: Column(
                        children: [
                          Icon(
                            Icons.video_collection,
                            color: hasYoutubeLink ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.onSurfaceVariant,
                            size: 24,
                          ),
                          Padding(
                            padding: EdgeInsets.only(top: 8.0),
                            child: Text('youtube', style: TextStyle(fontSize: 12, color: hasYoutubeLink ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                    ),
                  ),
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    _showShareDialog(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      children: [
                        Icon(
                          Icons.share_outlined,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 24,
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text('share', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: ScreenUtils.isSmallDevice(context) ? 35.0 : 55.0),
          ],
        ),
      ),
    );
  }

  void _showShareDialog(BuildContext context) async {
    try {
      // Load device ID
      final prefs = await SharedPreferences.getInstance();
      String? anonymousId = prefs.getString('device_id');
      
      if (anonymousId == null) {
        // Get device-specific ID
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          anonymousId = androidInfo.id; // Use Android ID
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          anonymousId = iosInfo.identifierForVendor; // Use Vendor ID for iOS
        } else {
          // Fallback for other platforms
          anonymousId = DateTime.now().millisecondsSinceEpoch.toString();
        }
        
        // Save the device ID for future use
        if (anonymousId != null) {
          await prefs.setString('device_id', anonymousId);
        }
      }

      // Load share link data
      final shareService = ShareService(widget.audioHandler.graphqlClient);
      final shareLinkData = await shareService.getShareLink(anonymousId!);
      
      if (!context.mounted || shareLinkData == null) return;
      
      // Generate share URL and message
      final shareUrl = shareLinkData.generateShareUrl(
        stationSlug: currentStation?.title != null ? currentStation?.slug : null,
      );
      
      final shareMessage = ShareUtils.formatShareMessage(
        shareLinkData: shareLinkData,
        stationName: currentStation?.title,
        stationSlug: currentStation?.slug,
      );
      
      // Show the share dialog
      ShareHandler.shareApp(
        context: context,
        shareUrl: shareUrl,
        shareMessage: shareMessage,
        stationName: currentStation?.title,
        shareLinkData: shareLinkData,
        showDialog: true,
      );
    } catch (e) {
      print('Error loading share dialog: $e');
      // Fallback to direct share without dialog
      if (context.mounted) {
        ShareHandler.shareApp(
          context: context,
          shareUrl: 'https://www.radio-crestin.com',
          shareMessage: 'Ascultă Radio Creștin - stații radio creștine online',
          stationName: currentStation?.title,
        );
      }
    }
  }

  Future<void> showSleepTimerDialog(BuildContext context) async {
    if (Platform.isIOS) {
      // Cupertino dialog for iOS
      return showCupertinoModalPopup<void>(
        context: context,
        builder: (BuildContext context) {
          return CupertinoActionSheet(
            title: const Text(
              'Programare închidere',
              style: TextStyle(fontSize: 18),
            ),
            actions: <Widget>[
              for (var minutes in [5, 10, 15, 30, 60])
                CupertinoActionSheetAction(
                  child: Text('$minutes minute'),
                  onPressed: () => setSleepTimer(context, Duration(minutes: minutes)),
                ),
              if (isTimerActive)
                CupertinoActionSheetAction(
                  child: const Text('Anulează închiderea'),
                  onPressed: cancelSleepTimer,
                ),
            ],
            cancelButton: CupertinoActionSheetAction(
              child: const Text('Renunță'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          );
        },
      );
    } else {
      // Material dialog for Android and other platforms
      return showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text(
              'Oprește radioul după:',
              style: TextStyle(fontSize: 18),
            ),
            backgroundColor: Theme.of(context).colorScheme.surface,
            content: SingleChildScrollView(
              child: Column(
                children: [5, 10, 15, 30, 60]
                    .map((minutes) => ListTile(
                          title: Text('$minutes minute'),
                          onTap: () => setSleepTimer(context, Duration(minutes: minutes)),
                        ))
                    .toList()
                  ..addAll(
                    isTimerActive
                        ? [
                            ListTile(
                              title: const Text('Anulează închiderea'),
                              onTap: cancelSleepTimer,
                            ),
                          ]
                        : [],
                  ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                child: const Text('Renunță'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          );
        },
      );
    }
  }

  void setSleepTimer(BuildContext context, Duration duration) {
    Navigator.of(context).pop();
    Fluttertoast.showToast(
        msg: "Radioul se va opri dupa ${duration.inMinutes} minute",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        timeInSecForIosWeb: 1,
        backgroundColor: Colors.black,
        textColor: Colors.white,
        fontSize: 16.0);

    setState(() {
      isTimerActive = true;
    });

    sleepTimer = Timer(duration, () {
      widget.audioHandler.stop();
      setState(() {
        isTimerActive = false;
      });
    });
  }

  void cancelSleepTimer() {
    if (sleepTimer != null) {
      sleepTimer!.cancel();
      sleepTimer = null;
      setState(() {
        isTimerActive = false;
      });
      Fluttertoast.showToast(
          msg: "Programarea închiderii a fost anulată",
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
          timeInSecForIosWeb: 1,
          backgroundColor: Colors.black,
          textColor: Colors.white,
          fontSize: 16.0);
    }
    Navigator.of(context).pop();
  }
}
