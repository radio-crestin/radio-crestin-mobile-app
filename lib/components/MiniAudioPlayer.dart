import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:sliding_up_panel/src/panel.dart';

class MiniAudioPlayer extends StatelessWidget {
  final Station? currentStation;
  final AudioHandler audioHandler;
  final PanelController panelController;

  const MiniAudioPlayer({
    super.key,
    required this.audioHandler,
    required this.panelController, this.currentStation,
  });

  @override
  Widget build(BuildContext context) {
    String displayTitle = currentStation?.displayTitle ?? "";
    String displaySubtitle = currentStation?.displaySubtitle ?? "";
    return GestureDetector(
      onTap: () {
        // developer.log("panelController: ${panelController.toString()}");
        // if(panelController.isPanelOpen) {
        //   panelController.close();
        //   return;
        // }
        panelController.open();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).bottomAppBarTheme.color,
          borderRadius: BorderRadius.circular(16.0),
        ),
        child: Column(
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
            SizedBox(height: Platform.isIOS ? 7 : 10),
            Row(
              children: <Widget>[
                SizedBox(
                  width: 52.0,
                  height: 52.0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12.0),
                    child: currentStation?.thumbnail,
                  ),
                ),
                const SizedBox(width: 16.0),
                // Song title and artist name
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        displayTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (displaySubtitle.isNotEmpty)
                        Text(
                          displaySubtitle,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 12.0, // Adjust font size as needed
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 3.0),
                // IconButton(
                //   icon: const Icon(Icons.skip_previous),
                //   color: Colors.white,
                //   iconSize: 32,
                //   tooltip: "Statia anterioare",
                //   onPressed: audioHandler.skipToPrevious,
                // ),
                StreamBuilder<PlaybackState>(
                  stream: audioHandler.playbackState.distinct(),
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
                              height: 48.0,
                              width: 48.0,
                              child: CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Theme
                                      .of(context)
                                      .iconTheme
                                      .color!,
                                ),
                              ),
                            ),
                          ),
                        Center(
                          child: playing
                              ? IconButton(
                            iconSize: 31,
                            tooltip: "Pauza",
                            onPressed: audioHandler.stop,
                            icon: const Icon(
                              Icons.pause_rounded,
                            ),
                            color: Theme
                                .of(context)
                                .iconTheme
                                .color!,
                          )
                              : IconButton(
                            iconSize: 31,
                            tooltip: "Start",
                            onPressed: audioHandler.play,
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                            ),
                            color: Theme
                                .of(context)
                                .iconTheme
                                .color!,
                          ),
                        )
                      ],
                    );
                  },
                ),
                const SizedBox(width: 9.0),
              ],
            )
          ],
        ),
      ),
    );
  }
}
