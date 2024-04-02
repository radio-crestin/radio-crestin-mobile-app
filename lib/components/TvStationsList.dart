import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:like_button/like_button.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/theme.dart';
import 'package:sliding_up_panel/src/panel.dart';

import '../types/Station.dart';
import 'DpadContainer.dart';

class TvStationsList extends StatelessWidget {
  const TvStationsList({
    super.key,
    required this.stations,
    required this.audioHandler,
    required this.panelController,
    this.currentStation,
    this.focusedStation,
  });

  final Station? currentStation;
  final Station? focusedStation;
  final List<Station> stations;
  final AppAudioHandler audioHandler;
  final PanelController? panelController;

  @override
  Widget build(BuildContext context) {
    return SliverFixedExtentList(
      itemExtent: 244.0,
      delegate: SliverChildBuilderDelegate(
        (context, itemIdx) {
          final station = stations[itemIdx];
          final isPlaying = station.slug == currentStation?.slug && audioHandler.player.playing == true;
          final isFocused = station.slug == focusedStation?.slug;

          return DpadContainer(
            onClick: () async {
              if(isPlaying) {
                await audioHandler.stop();
              } else {
                await audioHandler.playStation(station);
              }
            },
            onFocus: (bool isFocused) async {
              await audioHandler.focusStation(station);
            },
            onEvent: (RawKeyDownEvent event) async {
              print(event);
              if(event.logicalKey.keyLabel == 'Browser Favorites') {
                await audioHandler.setStationIsFavorite(station, !station.isFavorite);
              }
            },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(0.0),
                child: Container(
                  margin: const EdgeInsets.only(right: 14),
                  width: 220.0,
                  height: 220.0,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isFocused ? Colors.blue: Colors.transparent, // Set the color here
                      width: 8, // Set the border width
                    ),
                  ),
                  child: Container(
                    color: isFocused? Colors.blue: Colors.transparent,
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(12.0),
                        child: Stack(
                          children: [
                            Container(
                              color: Colors.white,
                              width: double.infinity,
                              height: double.infinity,
                              child: station.thumbnail,
                            ),
                            Stack(
                              children: [
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.topCenter,
                                        colors: [
                                          Colors.black.withOpacity(0.8),
                                          Colors.transparent, // Fully transparent
                                        ],
                                      ),
                                    ),
                                  ),
                                ),

                                Positioned(
                                  right: -4,
                                  top: -1,
                                  child: LikeButton(
                                    size: 39,
                                    bubblesSize: 39,
                                    isLiked: station.isFavorite,
                                    likeBuilder: (bool isLiked) {
                                      return Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Icon(
                                          isLiked? Icons.favorite_sharp: Icons.favorite_border_sharp,
                                          color: isLiked ? Theme.of(context).primaryColor : Colors.grey,
                                          size: 23,
                                        ),);
                                    },
                                    onTap: (bool isLiked) async {
                                      audioHandler.setStationIsFavorite(station, !isLiked);
                                      return !isLiked;
                                    },
                                  ),
                                ),
                                Container(
                                  width: double.infinity,
                                  height: double.infinity,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        station.displayTitle,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 21,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 2,
                                      ),
                                      Container(
                                          margin: const EdgeInsets.only(top: 0, bottom: 4),
                                          child: Column(
                                            children: [
                                              if (station.isUp == false)
                                                Text(
                                                  "Stație offline",
                                                  style: TextStyle(color: appTheme.primaryColor),
                                                ),
                                              Text(
                                                station.displaySubtitle,
                                                textAlign: TextAlign.left,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                ),
                                              )
                                            ],
                                          )),
                                      if (station.totalListeners != null && station.totalListeners! > 0)
                                        Row(
                                          children: [
                                            Container(
                                              width: 8,
                                              height: 8,
                                              margin: const EdgeInsets.only(right: 4),
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle, // Make it a circular shape
                                                color: station.isUp
                                                    ? Colors.green
                                                    : Colors.red, // Set the background color to green
                                              ),
                                            ),
                                            Text(
                                              '${station.totalListeners} ascultator${station.totalListeners == 1 ? "" : "i"}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ) else Container(
                                        height: 8,
                                      )
                                    ],
                                  ),
                                ),
                              ],
                            ),

                          ],
                        )
                    ),
                  ),
                ),
              ),
          );
        },
        childCount: stations.length, // Number of items in the list
      ),
    );
  }
}
