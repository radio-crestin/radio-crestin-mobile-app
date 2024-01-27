import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:like_button/like_button.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../appAudioHandler.dart';
import '../types/Station.dart';


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
  bool pageChangeDueToSwipe = true;
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
          if (currentStation != null && !filteredStations.contains(currentStation))
            currentStation!,
          ...filteredStations,
        ];
      });

      final newPageIndex = filteredStationsIncludingCurrentStation
          .indexWhere((item) => item.id == currentStation?.id);
      if (pageController.page != null && pageController.page != newPageIndex) {
        pageChangeDueToSwipe = false;
        pageController.jumpToPage(newPageIndex);
        pageChangeDueToSwipe = true;
      }
    }));

    _subscriptions
        .add(widget.audioHandler.currentStation.stream.listen((Station? value) {
      setState(() {
        currentStation = value;
      });

      final newPageIndex = filteredStationsIncludingCurrentStation
          .indexWhere((item) => item.id == currentStation?.id);
      if (pageController.page != null && pageController.page != newPageIndex) {
        pageChangeDueToSwipe = false;
        pageController
            .animateToPage(
          newPageIndex,
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
    final isFavorite = currentStation?.isFavorite ?? false;

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
                  margin: const EdgeInsets.only(top: 3.0),
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
              currentStation?.displayTitle ?? "",
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18.0),
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (PointerDownEvent details) {},
              onPointerUp: (PointerUpEvent details) {},
              child: SizedBox(
                width: 300.0,
                height: 300.0,
                child: PageView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  controller: pageController,
                  scrollDirection: Axis.horizontal,
                  itemCount: filteredStationsIncludingCurrentStation.length,
                  onPageChanged: (int index) {
                    if (pageChangeDueToSwipe) {
                      widget.audioHandler
                          .playStation(filteredStationsIncludingCurrentStation[index]);
                    }
                  },
                  itemBuilder: (BuildContext context, int itemIdx) {
                    final station = filteredStationsIncludingCurrentStation[itemIdx];

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
                        child: station.thumbnail,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 18.0),
            Text(
              currentStation?.songTitle ?? "Metadate indisponibile",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 21,
              ),
            ),
            Text(
              currentStation?.songArtist ?? "",
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
                InkWell(
                  onTap: widget.audioHandler.skipToPrevious,
                  child: const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Icon(
                      Icons.skip_previous,
                      size: 32,
                      color: Colors.black,
                    ),
                  ),
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
                InkWell(
                  onTap: widget.audioHandler.skipToNext,
                  child: const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Icon(
                      Icons.skip_next_rounded,
                      size: 32,
                      color: Colors.black,
                    ),
                  ),
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
                    child: Column(
                      children: [
                        Icon(
                          Icons.nights_stay_sharp,
                          color: isTimerActive ? Theme.of(context).primaryColor : Colors.black,
                          size: 24,
                        ),
                        Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text(
                            'somn',
                            style: TextStyle(
                                fontSize: 12,
                                color:
                                    isTimerActive ? Theme.of(context).primaryColor : Colors.black),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                LikeButton(
                  size: 39,
                  isLiked: isFavorite,
                  likeBuilder: (bool isLiked) {
                    return Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.favorite,
                        color: isLiked ? Colors.pinkAccent : Colors.grey,
                        size: 23,
                      ),
                    );
                  },
                  onTap: (bool isLiked) async {
                    widget.audioHandler.setStationIsFavorite(currentStation!, !isLiked);
                    return !isLiked;
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
                          child: Text('favorit', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
                if (currentStation?.displaySubtitle.isNotEmpty ?? false)
                  IconButton(
                    icon: const Icon(Icons.video_collection),
                    color: Colors.black,
                    iconSize: 24,
                    tooltip: 'Caută melodia pe Youtube',
                    onPressed: () async {
                      if (currentStation != null) {
                        final query = currentStation?.displaySubtitle ?? "";
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
                            child: Text('youtube', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  color: Colors.black,
                  iconSize: 24,
                  tooltip: 'Trimite aplicatia prietenilor tai',
                  onPressed: () {
                    if (currentStation != null) {
                      var linkMessage = "";
                      linkMessage += "${currentStation?.title ?? "Asculta Radio Crestin"}\n";
                      linkMessage +=
                          "https://share.radiocrestin.ro/${currentStation?.slug ?? ""}/${currentStation?.songId ?? ""}";

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
                          child: Text('share', style: TextStyle(fontSize: 12)),
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
            backgroundColor: Colors.white,
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
