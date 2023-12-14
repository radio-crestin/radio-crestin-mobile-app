import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/pages/HomePage.dart';
import 'package:share_plus/share_plus.dart';

import '../utils.dart';

class FullAudioPlayer extends StatelessWidget {
  final MediaItem? mediaItem;
  final AudioHandler audioHandler;

  const FullAudioPlayer({
    super.key,
    required this.mediaItem,
    required this.audioHandler,
  });

  @override
  Widget build(BuildContext context) {
    String stationTitle = mediaItem?.extras?['station_title'] ?? "";
    String songTitle = mediaItem?.extras?['song_title'] ?? "";
    String songArtist = mediaItem?.extras?['song_artist'] ?? "";
    String displayThumbnailUrl = mediaItem?.artUri.toString() ?? "";

    return Container(
      height: 80.0,
      decoration: BoxDecoration(
        color: Theme.of(context).bottomAppBarTheme.color!,
        border: Border.all(
          color: Theme.of(context).bottomAppBarTheme.color!,
          width: 5.0,
          style: BorderStyle.solid,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16.0),
          topRight: Radius.circular(16.0),
        ),
      ),
      child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 30,
                    height: 5,
                    decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: const BorderRadius.all(Radius.circular(12.0))),
                  ),
                ],
              ),
              const SizedBox(height: 20.0),
              Text(
                stationTitle,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.95),
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
                textAlign: TextAlign.left,
              ),
              const SizedBox(height: 24.0),
              Container(
                width: 220.0,
                height: 220.0,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.5),
                      spreadRadius: 0,
                      blurRadius: 2,
                      offset: const Offset(2, 1), // changes position of shadow
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  child: Utils.displayImage(displayThumbnailUrl, cache: false),
                ),
              ),
              const SizedBox(height: 24.0),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                // 8 pixels padding on left and right
                child: Text(
                  songTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                  ),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis, // Add this line to handle overflow
                ),
              ),
              const SizedBox(height: 10.0),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                // 8 pixels padding on left and right
                child: Text(
                  songArtist,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis, // Add this line to handle overflow
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                // Distribute space evenly across the children
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    color: Colors.white,
                    iconSize: 32,
                    tooltip: "Statia anterioare",
                    onPressed: audioHandler.skipToPrevious,
                  ),
                  const SizedBox(width: 24.0),
                  StreamBuilder<PlaybackState>(
                    stream: audioHandler.playbackState.distinct(),
                    builder: (context, snapshot) {
                      final playbackState = snapshot.data;
                      final processingState = playbackState?.processingState;
                      final playing = playbackState?.playing ?? true;
                      return Stack(
                        children: [
                          ClipOval(
                            child: Material(
                              color: Colors.pink, // Your button's background color
                              child: Padding(
                                padding: const EdgeInsets.all(6.0),
                                child: (processingState == AudioProcessingState.loading ||
                                    processingState == AudioProcessingState.buffering)
                                    ? Container(
                                  width: 48,
                                  height: 48,
                                  padding: const EdgeInsets.all(8.0),
                                  // Inner padding of CircularProgressIndicator
                                  child: const CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors
                                        .white), // Your CircularProgressIndicator color
                                  ),
                                )
                                    : IconButton(
                                  icon: (playing
                                      ? const Icon(Icons.pause_rounded,
                                      color: Colors.white)
                                      : const Icon(Icons.play_arrow_rounded,
                                      color: Colors.white)),
                                  iconSize: 32,
                                  onPressed: playing
                                      ? audioHandler.pause
                                      : audioHandler.play,
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
                    onPressed: audioHandler.skipToNext,
                    iconSize: 32,
                    icon: const Icon(
                      Icons.skip_next_rounded,
                    ),
                    color: Colors.white,
                  ),
                ],
              ),
              const SizedBox(height: 48.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                // Distribute space evenly across the children
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.bedtime_outlined),
                    color: Colors.white,
                    iconSize: 24,
                    onPressed: () {
                      // Handle loop action
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.favorite_border_sharp),
                    color: Colors.white,
                    iconSize: 24,
                    onPressed: () {
                      // Handle favorite action
                    },
                  ),
                  // IconButton(
                  //   icon: const Icon(Icons.cast),
                  //   color: Colors.white,
                  //   iconSize: 24,
                  //   onPressed: () {
                  //     // Handle loop action
                  //   },
                  // ),
                  // CastButton(audioHandler: audioHandler, mediaItem: mediaItem),

                  IconButton(
                    icon: const Icon(Icons.share_outlined),
                    color: Colors.white,
                    iconSize: 24,
                    tooltip: 'Trimite aplicatia prietenilor tai',
                    onPressed: () {
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
                  ),
                ],
              ),
              const SizedBox(height: 24.0),
            ],
          )),
    );
  }
}
