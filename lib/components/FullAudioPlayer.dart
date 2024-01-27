import 'dart:async';

import 'package:audio_service/audio_service.dart';
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
  final List<Station> filteredStationsIncludingCurrentStation;
  final Station? currentStation;

  const FullAudioPlayer(
      {super.key,
      required this.audioHandler,
      required this.slidingUpPanelController,
      required this.filteredStationsIncludingCurrentStation,
      required this.currentStation});

  @override
  _FullAudioPlayerState createState() => _FullAudioPlayerState();
}

class _FullAudioPlayerState extends State<FullAudioPlayer> {
  bool pageChangeDueToSwipe = false;
  final PageController pageController = PageController();
  final List _subscriptions = [];
  int currentPageIndex = 0;

  @override
  void initState() {
    super.initState();
    _subscriptions.add(widget.audioHandler.currentStation.listen((currentStation) {
      // setState(() {
      //   currentStation = value;
      // });
      if(pageChangeDueToSwipe == false) {
        final newPageIndex = widget.filteredStationsIncludingCurrentStation
            .indexWhere((item) => item.id == currentStation?.id);
        if (pageController.page != null && currentPageIndex != newPageIndex) {
          print("animateToPage");
          pageController
              .animateToPage(
            newPageIndex,
            duration: const Duration(milliseconds: 200),
            curve: Curves.ease,
          );
        }
      }
    }));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isFavorite = widget.currentStation?.isFavorite ?? false;

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
              widget.currentStation?.displayTitle ?? "",
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
                child: GestureDetector(
                  onPanDown: (details) {
                    // Set pageChangeDueToSwipe to true when the user starts swiping
                    pageChangeDueToSwipe = true;
                    print("onPanDown");
                  },
                  // onPanUp: (details) {
                  //   // Reset pageChangeDueToSwipe when the user stops swiping
                  //   pageChangeDueToSwipe = false;
                  // },
                  child: PageView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    controller: pageController,
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.filteredStationsIncludingCurrentStation.length,

                    allowImplicitScrolling: true,
                    onPageChanged: (int index) {
                      currentPageIndex = index;
                      if (pageChangeDueToSwipe) {
                        widget.audioHandler.playStation(widget.filteredStationsIncludingCurrentStation[index]);
                      }
                      pageChangeDueToSwipe = false;
                    },
                    itemBuilder: (BuildContext context, int itemIdx) {
                      final station = widget.filteredStationsIncludingCurrentStation[itemIdx];

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
            ),
            const SizedBox(height: 18.0),
            Text(
              widget.currentStation?.songTitle ?? "Metadate indisponibile",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 21,
              ),
            ),
            Text(
              widget.currentStation?.songArtist ?? "",
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
            const SizedBox(height: 70.0),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.bedtime_outlined),
                  color: Colors.black,
                  iconSize: 24,
                  onPressed: () {
                    showSleepTimerDialog(context);
                  },
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
                    widget.audioHandler.setStationIsFavorite(widget.currentStation!, !isLiked);
                    return !isLiked;
                  },
                ),
                if (widget.currentStation?.displaySubtitle.isNotEmpty ?? false)
                  IconButton(
                    icon: const Icon(Icons.video_collection),
                    color: Colors.black,
                    iconSize: 24,
                    tooltip: 'Caută melodia pe Youtube',
                    onPressed: () async {
                      if (widget.currentStation != null) {
                        final query = widget.currentStation?.displaySubtitle ?? "";
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
                  ),
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  color: Colors.black,
                  iconSize: 24,
                  tooltip: 'Trimite aplicatia prietenilor tai',
                  onPressed: () {
                    if (widget.currentStation != null) {
                      var linkMessage = "";
                      linkMessage += "${widget.currentStation?.title ?? "Asculta Radio Crestin"}\n";
                      linkMessage +=
                          "https://share.radiocrestin.ro/${widget.currentStation?.slug ?? ""}/${widget.currentStation?.songId ?? ""}";

                      Share.share(
                          remoteConfig.getString("share_app_station_message") + linkMessage);
                    } else {
                      Share.share(remoteConfig.getString("share_app_message"));
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 44.0),
          ],
        ),
      ),
    );
  }

  Future<void> showSleepTimerDialog(BuildContext context) async {
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
          surfaceTintColor: Colors.transparent,
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
