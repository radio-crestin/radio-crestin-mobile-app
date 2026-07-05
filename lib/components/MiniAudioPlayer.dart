import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/widgets/animated_play_button.dart';
import 'package:radio_crestin/widgets/station_type_badge.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

import '../services/playlist_controller.dart';
import '../types/playlist_item.dart';
import '../utils/station_ui.dart';

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
            SizedBox(height: Platform.isIOS ? 8 : 10),
            SizedBox(
              height: 62,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 60.0,
                    height: 60.0,
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
                        Row(
                          children: [
                            if (currentStation != null &&
                                currentStation!.stationType !=
                                    StationMediaType.radio) ...[
                              StationTypeBadge(
                                type: currentStation!.stationType,
                                color: Colors.white,
                                contentColor:
                                    Theme.of(context).bottomAppBarTheme.color ??
                                        Theme.of(context).primaryColor,
                                compact: true,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                displayTitle,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        _MiniSubtitle(
                          station: currentStation,
                          fallback: displaySubtitle,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  IgnoreDraggableWidget(
                    child: AnimatedPlayButton(
                      playbackStateStream: audioHandler.playbackState,
                      iconSize: 38,
                      iconColor: Theme.of(context).iconTheme.color!,
                      onPlay: audioHandler.play,
                      onPause: audioHandler.pause,
                      onStop: audioHandler.stop,
                    ),
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

/// Subtitle line for the mini player. For playlist stations it tracks the
/// current playlist item's title live; otherwise it shows the station's
/// now-playing subtitle.
class _MiniSubtitle extends StatelessWidget {
  const _MiniSubtitle({required this.station, required this.fallback});

  final Station? station;
  final String fallback;

  Widget _text(String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Text(
      value,
      style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13.0),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = station;
    if (st == null) return _text(fallback);
    if (st.isPlaylist) {
      final label = computeStationSubtitle(
            type: StationMediaType.playlist,
            songLine: '',
            isRomanian: true,
          ) ??
          '';
      final controller = GetIt.instance<PlaylistController>();
      return StreamBuilder<PlaylistItem?>(
        stream: controller.currentItem.stream,
        initialData: controller.currentItem.valueOrNull,
        builder: (context, snapshot) {
          final title = snapshot.data?.title ?? '';
          return _text(title.isNotEmpty ? title : label);
        },
      );
    }
    // TV with no song → "Transmisiune live"; radio keeps its song line.
    final subtitle = computeStationSubtitle(
      type: st.stationType,
      songLine: fallback,
      isRomanian: true,
      tvLiveFallback: true,
    );
    return _text(subtitle ?? fallback);
  }
}
