import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../appAudioHandler.dart';
import '../utils.dart';

class FullAudioPlayer extends StatefulWidget {
  final AppAudioHandler audioHandler;
  final CustomPanelController slidingUpPanelController;

  const FullAudioPlayer(
      {super.key, required this.audioHandler, required this.slidingUpPanelController});

  @override
  _FullAudioPlayerState createState() => _FullAudioPlayerState();
}

class _FullAudioPlayerState extends State<FullAudioPlayer> {
  bool pageChangeDueToSwipe = true;
  List<MediaItem> stationsMediaItems = [];
  MediaItem? mediaItem;
  final PageController pageController = PageController();
  final List _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _subscriptions.add(widget.audioHandler.stationsMediaItems.listen((value) {
      setState(() {
        stationsMediaItems = value;
      });
    }));
    _subscriptions.add(widget.audioHandler.mediaItem.listen((value) {
      setState(() {
        mediaItem = value;
      });
      final newPage = stationsMediaItems.indexWhere((item) => item.id == mediaItem?.id);
      if (pageController.page != null && pageController.page != newPage) {
        pageChangeDueToSwipe = false;
        pageController
            .animateToPage(
          newPage,
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
        )
            .then((_) {
          pageChangeDueToSwipe = true;
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
    final Color primaryColor = Theme.of(context).primaryColor;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
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
                  margin: EdgeInsets.only(top: 3.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: const BorderRadius.all(Radius.circular(12.0))),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 17.0),
            Text(
              mediaItem?.extras?['station_title'] ?? "",
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18.0),
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (PointerDownEvent details) {
              },
              onPointerUp: (PointerUpEvent details) {
              },
              child: SizedBox(
                width: 300.0,
                height: 300.0,
                child: PageView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  controller: pageController,
                  scrollDirection: Axis.horizontal,
                  itemCount: stationsMediaItems.length,
                  onPageChanged: (int index) {
                    if (pageChangeDueToSwipe) {
                      widget.audioHandler.playMediaItem(stationsMediaItems[index]);
                    }
                  },
                  itemBuilder: (BuildContext context, int itemIdx) {
                    final item = stationsMediaItems[itemIdx];
                    String displayThumbnailUrl = item.artUri.toString();

                    return Container(
                      width: 260.0,
                      height: 260.0,
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white,
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
                        child: Utils.displayImage(
                          displayThumbnailUrl,
                          fallbackImageUrl: item.extras?["station_thumbnail_url"],
                          cache: displayThumbnailUrl == item.extras?["station_thumbnail_url"],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 18.0),
            Text(
              (mediaItem != null &&
                      mediaItem?.extras?['song_title'] != null &&
                      mediaItem?.extras?['song_title'] != "")
                  ? (mediaItem?.extras?['song_title'] ?? "Metadate indisponibile")
                  : "Metadate indisponibile",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 21,
              ),
            ),
            Text(
              mediaItem?.extras?['song_artist'] ?? "",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[700],
              ),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  color: Colors.black,
                  iconSize: 32,
                  tooltip: "Statia anterioare",
                  onPressed: widget.audioHandler.skipToPrevious,
                ),
                const SizedBox(width: 24.0),
                StreamBuilder<PlaybackState>(
                  stream: widget.audioHandler.playbackState.distinct(),
                  builder: (context, snapshot) {
                    final playbackState = snapshot.data;
                    final processingState = playbackState?.processingState;
                    final playing = playbackState?.playing ?? true;
                    return Stack(
                      children: [
                        ClipOval(
                          child: Material(
                            color: Colors.pink,
                            child: Padding(
                              padding: const EdgeInsets.all(6.0),
                              child: (processingState == AudioProcessingState.loading ||
                                      processingState == AudioProcessingState.buffering)
                                  ? Container(
                                      width: 48,
                                      height: 48,
                                      padding: const EdgeInsets.all(8.0),
                                      child: const CircularProgressIndicator(
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      icon: (playing
                                          ? const Icon(Icons.pause_rounded, color: Colors.white)
                                          : const Icon(Icons.play_arrow_rounded,
                                              color: Colors.white)),
                                      iconSize: 32,
                                      onPressed: playing
                                          ? widget.audioHandler.pause
                                          : widget.audioHandler.play,
                                    ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(width: 24.0),
                IconButton(
                  tooltip: "Statia urmatoare",
                  onPressed: widget.audioHandler.skipToNext,
                  iconSize: 32,
                  icon: const Icon(
                    Icons.skip_next_rounded,
                  ),
                  color: Colors.black,
                ),
              ],
            ),
            const SizedBox(height: 90.0),
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
                    child: const Column(
                      children: [
                        Icon(
                          Icons.nights_stay_sharp,
                          color: Colors.black,
                          size: 24,
                        ),
                        Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text('Somn', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  customBorder: CircleBorder(),
                  onTap: () async {
                    if (mediaItem != null) {
                      if (mediaItem?.extras?['is_favorite'] == "true") {
                        await widget.audioHandler.setMediaItemIsFavorite(mediaItem!, false);
                      } else {
                        await widget.audioHandler.setMediaItemIsFavorite(mediaItem!, true);
                      }
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      children: [
                        Icon(
                          mediaItem?.extras?['is_favorite'] == "true"
                              ? Icons.favorite_sharp
                              : Icons.favorite_border_sharp,
                          color: mediaItem?.extras?['is_favorite'] == "true"
                              ? primaryColor
                              : Colors.black,
                          size: 24,
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text('Favorit', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
                if (mediaItem != null &&
                    (!mediaItem?.extras?['song_artist'].isEmpty ||
                        !mediaItem?.extras?['song_title'].isEmpty))
                  InkWell(
                    customBorder: CircleBorder(),
                    onTap: () async {
                      if (mediaItem != null) {
                        final query =
                            "${mediaItem?.extras?['song_artist']} - ${mediaItem?.extras?['song_title']}";
                        final encodedQuery = Uri.encodeQueryComponent(query);

                        final searchUrl = 'https://www.youtube.com/results?q=$encodedQuery';

                        if (!await launchUrl(Uri.parse(searchUrl))) {
                          Fluttertoast.showToast(
                              msg: "A apărut o eroare neașteptată în lansarea YouTube.",
                              toastLength: Toast.LENGTH_SHORT,
                              gravity: ToastGravity.BOTTOM,
                              timeInSecForIosWeb: 1,
                              backgroundColor: Colors.black,
                              textColor: Colors.white,
                              fontSize: 16.0);
                        }
                      } else {
                        Fluttertoast.showToast(
                            msg: "Vă rugam să alegeți o statie de radio.",
                            toastLength: Toast.LENGTH_SHORT,
                            gravity: ToastGravity.BOTTOM,
                            timeInSecForIosWeb: 1,
                            backgroundColor: Colors.black,
                            textColor: Colors.white,
                            fontSize: 16.0);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10.0),
                      child: const Column(
                        children: [
                          Icon(
                            Icons.video_collection,
                            color: Colors.black,
                            size: 24,
                          ),
                          Padding(
                            padding: EdgeInsets.only(top: 8.0),
                            child: Text('YouTube', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
                InkWell(
                  customBorder: CircleBorder(),
                  onTap: () {
                    if (mediaItem != null) {
                      var linkMessage = "";
                      linkMessage += "${mediaItem?.title ?? "Asculta Radio Crestin"}\n";
                      linkMessage +=
                          "https://share.radiocrestin.ro/${mediaItem?.extras?['station_slug'] ?? ""}/${mediaItem?.extras?['song_id'] ?? ""}";

                      Share.share(
                          remoteConfig.getString("share_app_station_message") + linkMessage);
                    } else {
                      Share.share(remoteConfig.getString("share_app_message"));
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(10.0),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.share_outlined,
                          color: Colors.black,
                          size: 24,
                        ),
                        Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text('Share', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 55.0),
          ],
        ),
      ),
    );
  }

  Future<void> showSleepTimerDialog(BuildContext context) async {
    if (Platform.isIOS) {
      // Cupertino dialog for iOS
      return showCupertinoModalPopup<void>(
        context: context,
        builder: (BuildContext context) {
          return CupertinoActionSheet(
            title: const Text(
              'Oprește radioul după:',
              style: TextStyle(fontSize: 18),
            ),
            actions: <Widget>[
              for (var minutes in [5, 10, 30, 60])
                CupertinoActionSheetAction(
                  child: Text('$minutes minute'),
                  onPressed: () => setSleepTimer(context, Duration(minutes: minutes)),
                ),
            ],
            cancelButton: CupertinoActionSheetAction(
              child: const Text('Închide'),
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
            backgroundColor: Colors.white,
            content: SingleChildScrollView(
              child: Column(
                children: [5, 10, 30, 60]
                    .map((minutes) => ListTile(
                          title: Text('$minutes minute'),
                          onTap: () => setSleepTimer(context, Duration(minutes: minutes)),
                        ))
                    .toList(),
              ),
            ),
            actions: <Widget>[
              TextButton(
                child: const Text('Închide'),
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

    Timer(duration, () {
      widget.audioHandler.stop();
    });
  }
}
