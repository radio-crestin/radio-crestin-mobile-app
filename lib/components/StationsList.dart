import 'package:flutter/material.dart';
import 'package:like_button/like_button.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/theme.dart';
import 'package:sliding_up_panel/src/panel.dart';

import '../types/Station.dart';

class StationsList extends StatelessWidget {
  const StationsList({
    super.key,
    required this.stations,
    required this.audioHandler,
    required this.panelController, this.currentStation,
  });

  final Station? currentStation;
  final List<Station> stations;
  final AppAudioHandler audioHandler;
  final PanelController? panelController;

  @override
  Widget build(BuildContext context) {
    return SliverFixedExtentList(
      itemExtent: 135.0,
      delegate: SliverChildBuilderDelegate(
        (context, itemIdx) {
          final station = stations[itemIdx];
          final isSelected = station.slug == currentStation?.slug;

          return GestureDetector(
              onTap: () async {
                await audioHandler.playStation(station);
              },
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected ? Colors.grey.shade300 : Colors.grey.shade100,
                  borderRadius: const BorderRadius.all(Radius.circular(16.0)),
                ),
                child: Stack(
                  children: [
                    Row(
                      children: [
                        Container(
                          margin: const EdgeInsets.only(right: 14),
                          width: 100.0,
                          height: 100.0,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12.0),
                            child: station.thumbnail,
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                station.displayTitle,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.normal,
                                  fontSize: 16,
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
                                      if (station.displaySubtitle != "")
                                        Text(
                                          station.displaySubtitle ?? "",
                                          textAlign: TextAlign.left,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isSelected ? Colors.grey[700] : Colors.grey[600],
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
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                )
                            ],
                          ),
                        )
                      ],
                    ),
                    Positioned(
                      right: -7,
                      bottom: 0,
                      child: LikeButton(
                        size: 39,
                        bubblesSize: 39,
                        isLiked: station.isFavorite,
                        likeBuilder: (bool isLiked) {
                          return Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(
                              Icons.favorite,
                              color: isLiked ? Colors.pinkAccent : Colors.grey,
                              size: 23,
                            ),);
                        },
                        onTap: (bool isLiked) async {
                          audioHandler.setStationIsFavorite(station, !isLiked);
                          return !isLiked;
                        },
                      ),
                    )
                  ],
                ),
              ));
        },
        childCount: stations.length, // Number of items in the list
      ),
    );
  }
}
