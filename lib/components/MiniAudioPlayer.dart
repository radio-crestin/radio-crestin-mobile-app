import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/widgets/animated_play_button.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

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
            SizedBox(
              height: 52,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
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
                              fontSize: 12.0,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  AnimatedPlayButton(
                    key: ValueKey('mini-play-${currentStation?.id}'),
                    playbackStateStream: audioHandler.playbackState,
                    iconSize: 36,
                    iconColor: Theme.of(context).iconTheme.color!,
                    onPlay: audioHandler.play,
                    onPause: audioHandler.pause,
                    onStop: audioHandler.stop,
                  ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}
