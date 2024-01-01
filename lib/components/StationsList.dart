import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/utils.dart';
import 'package:sliding_up_panel/src/panel.dart';

class StationsList extends StatelessWidget {
  const StationsList(
      {super.key,
      required this.stationsMediaItems,
      required this.mediaItem,
      required this.audioHandler,
      required this.panelController});

  final List<MediaItem> stationsMediaItems;
  final MediaItem? mediaItem;
  final AppAudioHandler audioHandler;
  final PanelController? panelController;

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme
        .of(context)
        .primaryColor;

    return SliverFixedExtentList(
      itemExtent: 135.0,
      delegate: SliverChildBuilderDelegate(
            (context, itemIdx) {
          final item = stationsMediaItems[itemIdx];
          final isSelected = item.extras?['station_slug'] == mediaItem?.extras?['station_slug'];

          return GestureDetector(
              onTap: () async {
                await audioHandler.playMediaItem(item);
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
                            child: Utils.displayImage(
                              item.artUri.toString(),
                              fallbackImageUrl: item.extras?["station_thumbnail_url"],
                              cache: item.artUri.toString() == item.extras?["station_thumbnail_url"],
                            ),
                          ),
                        ),

                        Expanded(
                          flex: 1,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.displayTitle ?? "",
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
                                      if (item.extras?["station_is_up"] == false)
                                        Text(
                                          "Stație offline",
                                          style: TextStyle(color: appTheme.primaryColor),
                                        ),
                                      if (item.displaySubtitle != "")
                                        Text(
                                          item.displaySubtitle ?? "",
                                          textAlign: TextAlign.left,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isSelected? Colors.grey[700]: Colors.grey[600],
                                            fontSize: 13,
                                          ),
                                        )
                                    ],
                                  )),
                              if (item.extras?['total_listeners'] != null &&
                                  item.extras?['total_listeners'] > 0)
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      margin: const EdgeInsets.only(right: 4),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle, // Make it a circular shape
                                        color: item.extras?["station_is_up"]
                                            ? Colors.green
                                            : Colors.red, // Set the background color to green
                                      ),
                                    ),
                                    Text(
                                      '${item.extras?['total_listeners']} ascultator${item.extras?['total_listeners'] == 1 ? "" : "i"}',
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
                    Stack(
                      children: [
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Transform.translate(
                            offset: Offset(10, 0),
                            child: IconButton(
                              icon: item?.extras?['is_favorite'] == "true"
                                  ? const Icon(Icons.favorite_sharp)
                                  : const Icon(Icons.favorite_border_sharp),
                              color: primaryColor,
                              iconSize: 20,
                              onPressed: () async {
                                if (item.extras?['is_favorite'] == "true") {
                                  await audioHandler.setMediaItemIsFavorite(item, false);
                                } else {
                                  await audioHandler.setMediaItemIsFavorite(item, true);
                                }
                              },
                            ),
                          ),
                        )
                      ],
                    )
                  ],
                ),
              ));
        },
        childCount: stationsMediaItems.length, // Number of items in the list
      ),
    );
  }
}
