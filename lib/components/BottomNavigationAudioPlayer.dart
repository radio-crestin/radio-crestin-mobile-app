import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:text_scroll/text_scroll.dart';

import '../utils.dart';

class BottomNavigationAudioPlayer extends StatelessWidget {
  final Function() onPlay;
  final Function() onPause;
  final Function() onPreviousStation;
  final Function() onNextStation;

  final int stationIdx;
  final String displayTitle;
  final String displaySubtitle;
  final String displayThumbnailUrl;
  final bool isElevated;
  final bool isVisible;
  final PlaybackState? appPlaybackState;
  final bool playerStarted;

  const BottomNavigationAudioPlayer({
    required this.isElevated,
    required this.isVisible,
    required this.stationIdx,
    required this.displayTitle,
    required this.displaySubtitle,
    required this.displayThumbnailUrl,
    required this.onPlay,
    required this.onPause,
    required this.onPreviousStation,
    required this.onNextStation,
    required this.appPlaybackState,
    required this.playerStarted,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: isVisible ? 70.0 : 0,
      child: BottomAppBar(
        elevation: isElevated ? null : 0.0,
        color: Colors.grey[900],
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Utils.displayImage(displayThumbnailUrl, cache: false),
            SizedBox(width: 14.0),
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextScroll(
                    displayTitle,
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.left,
                    mode: TextScrollMode.endless,
                    velocity: Velocity(pixelsPerSecond: Offset(10, 0)),
                    numberOfReps: 5,
                  ),
                  displaySubtitle.isNotEmpty? TextScroll(
                    displaySubtitle,
                    style: TextStyle(color: Colors.white),
                    textAlign: TextAlign.left,
                    mode: TextScrollMode.endless,
                    velocity: Velocity(pixelsPerSecond: Offset(10, 0)),
                    numberOfReps: 5,
                  ): SizedBox(height: 0,),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                  icon: Icon(Icons.skip_previous),
                  color: Colors.white,
                  onPressed: () {
                    onPreviousStation();
                  },
                ),
                playerStarted
                    ? (appPlaybackState?.processingState == AudioProcessingState.ready || appPlaybackState?.processingState == AudioProcessingState.buffering)
                        ? IconButton(
                            icon: Icon(Icons.pause),
                            color: Colors.white,
                            onPressed: () {
                              onPause();
                            },
                          )
                        : IconButton(
                            icon: SpinKitRing(
                              color: Colors.white,
                                lineWidth: 3,
                              size: 24,
                            ),
                            color: Colors.white,
                            onPressed: () {
                              onPause();
                            },
                          )
                    : IconButton(
                        icon: Icon(Icons.play_arrow),
                        color: Colors.white,
                        onPressed: () {
                          onPlay();
                        },
                      ),
                IconButton(
                  icon: Icon(Icons.skip_next),
                  color: Colors.white,
                  onPressed: () {
                    onNextStation();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
