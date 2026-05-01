import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/theme.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

import '../services/analytics_service.dart';
import '../types/Station.dart';

class StationsList extends StatelessWidget {
  const StationsList({
    super.key,
    required this.stations,
    required this.audioHandler,
    required this.panelController,
    required this.favoriteSlugs,
    this.currentStation,
    this.isFavoritesList = false,
  });

  final Station? currentStation;
  final List<Station> stations;
  final AppAudioHandler audioHandler;
  final PanelController? panelController;
  final List<String> favoriteSlugs;
  final bool isFavoritesList;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 700,
        mainAxisExtent: 105,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, itemIdx) {
          final station = stations[itemIdx];
          final isSelected = station.slug == currentStation?.slug;

          return KeyedSubtree(
            key: ValueKey('station-${station.slug}'),
            child: RepaintBoundary(
            child: GestureDetector(
              onTap: () async {
                AnalyticsService.instance.capture('button_clicked', {'button_name': 'station_tap', 'station_id': station.id, 'station_slug': station.slug, 'from_favorites': isFavoritesList});
                await audioHandler.playStation(station, fromFavorites: isFavoritesList);
              },
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                    ? Theme.of(context).cardColorSelected
                    : Theme.of(context).cardColor,
                  borderRadius: const BorderRadius.all(Radius.circular(16.0)),
                  border: Border.all(
                    color: isSelected
                      ? const Color(0xFF555555).withValues(alpha: 0.35)
                      : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Stack(
                  children: [
                    Row(
                      children: [
                        Container(
                          margin: const EdgeInsets.only(right: 14),
                          width: 70.0,
                          height: 70.0,
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
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      station.displayTitle,
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurface,
                                        fontWeight: FontWeight.normal,
                                        fontSize: 16,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                  ),
                                  if (station.averageRating > 0) ...[
                                    const SizedBox(width: 6),
                                    Icon(
                                      Icons.star_rounded,
                                      size: 14,
                                      color: const Color(0xFFED8A19),
                                    ),
                                    const SizedBox(width: 1),
                                    Text(
                                      station.averageRating.toStringAsFixed(1),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFFED8A19),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              SizedBox(
                                height: 22,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  layoutBuilder: (currentChild, previousChildren) => Stack(
                                    alignment: Alignment.centerLeft,
                                    children: [...previousChildren, if (currentChild != null) currentChild],
                                  ),
                                  child: Container(
                                    key: ValueKey('meta-${station.id}-${station.songTitle}-${station.songArtist}'),
                                    alignment: Alignment.centerLeft,
                                    child: station.isUp == false
                                      ? Text(
                                          "Stație posibil indisponibilă",
                                          style: const TextStyle(color: Color(0xFFF87171)),
                                        )
                                      : station.songTitle != ""
                                        ? Text(
                                            station.songArtist != ""
                                              ? "${station.songTitle} - ${station.songArtist}"
                                              : station.songTitle,
                                            textAlign: TextAlign.left,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                              fontSize: 13,
                                            ),
                                          )
                                        : Text(
                                            "Metadate indisponibile",
                                            textAlign: TextAlign.left,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                                              fontSize: 13,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: 18,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  layoutBuilder: (currentChild, previousChildren) => Stack(
                                    alignment: Alignment.centerLeft,
                                    children: [...previousChildren, if (currentChild != null) currentChild],
                                  ),
                                  child: station.totalListeners != null && station.totalListeners! > 0
                                    ? Row(
                                        key: ValueKey('listeners-${station.id}-${station.totalListeners}'),
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            margin: const EdgeInsets.only(right: 4),
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: station.isUp
                                                  ? AppColors.success
                                                  : AppColors.offline,
                                            ),
                                          ),
                                          Text(
                                            '${station.totalListeners} ascultator${station.totalListeners == 1 ? "" : "i"}',
                                            style: TextStyle(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      )
                                    : SizedBox.shrink(key: ValueKey('no-listeners-${station.id}')),
                                ),
                              )
                            ],
                          ),
                        )
                      ],
                    ),
                    Positioned(
                      right: -7,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final isLiked = favoriteSlugs.contains(station.slug);
                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'favorite_toggle', 'station_slug': station.slug, 'station_id': station.id, 'is_favorite': !isLiked});
                          HapticFeedback.lightImpact();
                          audioHandler.setStationIsFavorite(station, !isLiked);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            transitionBuilder: (child, animation) => ScaleTransition(
                              scale: animation,
                              child: child,
                            ),
                            child: Icon(
                              favoriteSlugs.contains(station.slug)
                                  ? Icons.favorite_sharp
                                  : Icons.favorite_border_sharp,
                              key: ValueKey('fav-${station.slug}-${favoriteSlugs.contains(station.slug)}'),
                              color: favoriteSlugs.contains(station.slug)
                                  ? Theme.of(context).primaryColor
                                  : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                              size: 23,
                            ),
                          ),
                        ),
                      ),
                    )
                  ],
                ),
              )),
            ),
          );
        },
        childCount: stations.length, // Number of items in the list
      ),
    );
  }
}
