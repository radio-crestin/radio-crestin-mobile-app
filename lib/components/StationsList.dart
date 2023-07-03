import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/utils.dart';
import 'package:text_scroll/text_scroll.dart';

class StationsList extends StatelessWidget {
  const StationsList({Key? key, required this.stations, required this.selectedStationIdx, required this.onStationSelected, required this.hideButtonController}) : super(key: key);
  final List<Query$GetStations$stations> stations;
  final int selectedStationIdx;
  final void Function(int stationIdx) onStationSelected;
  final ScrollController hideButtonController;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 100),
      controller: hideButtonController,
      itemCount: stations.length,
      itemBuilder: (context, stationIdx) {
        final station = stations[stationIdx];
        final stationMetadata = Utils.getStationMetadata(station);
        final isSelected = stationIdx == selectedStationIdx;
        return ListTile(
            tileColor: isSelected ? appTheme.highlightColor : null,
            leading: SizedBox(
            width: 50,
            height: 50,
            child: Utils.displayImage(stationMetadata.artUri.toString(), cache: stationMetadata.artUri.toString() == station.thumbnail_url),
          ),
          title: Row(
            children: [
              Text(stationMetadata.displayTitle ?? ""),
              const Spacer(),
              Text("${station.total_listeners}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(width: 4),
              const Icon(Icons.visibility, size: 14, color: Colors.grey),
            ],
          ),
          subtitle: station.uptime?.is_up == false ? Text(
            "Statie offline",
            style: TextStyle(color: appTheme.primaryColor),
          ): TextScroll(
            stationMetadata.displaySubtitle ?? "",
            textAlign: TextAlign.left,
            mode: TextScrollMode.endless,
            velocity: const Velocity(pixelsPerSecond: Offset(10, 0)),
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
