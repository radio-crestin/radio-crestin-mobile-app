import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/utils.dart';

class QueueList extends StatelessWidget {
  const QueueList(
      {Key? key,
      required this.queue,
      required this.mediaItem,
      required this.hideButtonController,
      required this.audioHandler})
      : super(key: key);
  final List<MediaItem> queue;
  final MediaItem? mediaItem;
  final ScrollController hideButtonController;
  final AppAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 100),
      cacheExtent: 20.0,
      controller: hideButtonController,
      itemCount: queue.length,
      itemBuilder: (context, itemIdx) {
        final item = queue[itemIdx];
        final isSelected = item.id == mediaItem?.id;
        return ListTile(
            tileColor: isSelected ? appTheme.highlightColor : null,
            leading: SizedBox(
              width: 50,
              height: 50,
              child: Utils.displayImage(item.artUri.toString(),
                  cache: item.artUri.toString() == item.extras?["thumbnail_url"]),
            ),
            title: Row(
              children: [
                Text(item.displayTitle ?? ""),
                const Spacer(),
                Text("${item.extras?["total_listeners"] ?? 0}",
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(width: 4),
                const Icon(Icons.visibility, size: 14, color: Colors.grey),
              ],
            ),
            subtitle: item.extras?["station_is_up"] == false
                ? Text(
                    "Statie offline",
                    style: TextStyle(color: appTheme.primaryColor),
                  )
                : Text(
                    item.displaySubtitle ?? "",
                    textAlign: TextAlign.left,
                  ),
            onTap: () async {
              audioHandler.playMediaItem(item);
            });
      },
    );
  }
}
