import 'package:fast_cached_network_image/fast_cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/utils.dart';
import 'package:text_scroll/text_scroll.dart';

class StationsList extends StatelessWidget {
  const StationsList({Key? key, required this.stations, required this.onStationSelected, required this.hideButtonController}) : super(key: key);
  final List<Query$GetStations$stations> stations;
  final void Function(int stationIdx) onStationSelected;
  final ScrollController hideButtonController;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: hideButtonController,
      itemCount: stations.length,
      itemBuilder: (context, stationIdx) {
        final station = stations[stationIdx];
        final stationMetadata = Utils.getStationMetadata(station);
        return ListTile(
          leading: SizedBox(
            width: 50,
            height: 50,
            child: Utils.displayImage(stationMetadata.artUri.toString(), cache: stationMetadata.artUri.toString() == station.thumbnail_url),
          ),
          title: Text(stationMetadata.displayTitle ?? ""),
          subtitle: TextScroll(
            stationMetadata.displaySubtitle ?? "",
            textAlign: TextAlign.left,
            mode: TextScrollMode.endless,
            velocity: Velocity(pixelsPerSecond: Offset(10, 0)),
            numberOfReps: 5,
          ),
          onTap: () {
            onStationSelected(stationIdx);
          }
        );
      },
    );
  }
}
