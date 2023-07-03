import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:text_scroll/text_scroll.dart';

import '../utils.dart';

class BottomNavigationAudioPlayer extends StatelessWidget {
  final int stationIdx;
  final String displayTitle;
  final String displaySubtitle;
  final String displayThumbnailUrl;
  final bool isElevated;
  final bool isVisible;
  final AudioHandler audioHandler;

  const BottomNavigationAudioPlayer({
    super.key,
    required this.isElevated,
    required this.isVisible,
    required this.stationIdx,
    required this.displayTitle,
    required this.displaySubtitle,
    required this.displayThumbnailUrl,
    required this.audioHandler,
  });

  @override
  Widget build(BuildContext context) {

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: isVisible ? 80.0 : 0,

      decoration: BoxDecoration(
        color: Theme.of(context).bottomAppBarTheme.color!,
        border: Border.all(
            color: Theme.of(context).bottomAppBarTheme.color!,
            width: 5.0,
            style: BorderStyle.solid,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        // crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.max,
        children: [
          SizedBox(
            width: 55.0,
            height: 55.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: Utils.displayImage(displayThumbnailUrl, cache: false),
            ),
          ),
          const SizedBox(width: 9.0),
          Expanded(
            flex: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextScroll(
                  displayTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.left,
                  mode: TextScrollMode.endless,
                  velocity: const Velocity(pixelsPerSecond: Offset(10, 0)),
                  numberOfReps: 5,
                ),
                displaySubtitle.isNotEmpty
                    ? Flexible(
                        child: Text(
                        displaySubtitle,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.left,
                      ))
                    : const SizedBox(
                        height: 0,
                      ),
              ],
            ),
          ),
          Row(
            children: [
              // SizedBox(
              //   height: 1,
              //   width: 6,
              // ),
              // IconButton(
              //   tooltip: "Statia anterioare",
              //   onPressed: audioHandler.skipToPrevious,
              //   icon: const Icon(
              //     Icons.skip_previous_rounded,
              //   ),
              //   color: Theme.of(context).iconTheme.color,
              // ),
              SizedBox(
                height: 40.0,
                width: 40.0,
                child: StreamBuilder<PlaybackState>(
                  stream: audioHandler.playbackState,
                  builder: (context, snapshot) {
                    final playbackState = snapshot.data;
                    final processingState = playbackState?.processingState;
                    final playing = playbackState?.playing ?? true;
                    return Stack(
                      children: [
                        if (processingState == AudioProcessingState.loading ||
                            processingState == AudioProcessingState.buffering)
                          Center(
                            child: SizedBox(
                              height: 37.0,
                              width: 37.0,
                              child: CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Theme.of(context).iconTheme.color!,
                                ),
                              ),
                            ),
                          ),
                        Center(
                          child: playing
                              ? IconButton(
                                  tooltip: "Pauza",
                                  onPressed: audioHandler.pause,
                                  icon: const Icon(
                                    Icons.pause_rounded,
                                  ),
                            color: Theme.of(context).iconTheme.color!,
                                )
                              : IconButton(
                                  tooltip: "Start",
                                  onPressed: audioHandler.play,
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                  ),
                            color: Theme.of(context).iconTheme.color!,
                                ),
                        )
                      ],
                    );
                  },
                ),
              ),
              IconButton(
                tooltip: "Statia urmatoare",
                onPressed: audioHandler.skipToNext,
                icon: const Icon(
                  Icons.skip_next_rounded,
                ),
                color: Theme.of(context).iconTheme.color!,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
