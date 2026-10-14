import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/theme.dart';
import 'package:radio_crestin/widgets/station_type_badge.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

import '../services/analytics_service.dart';
import '../services/playlist_controller.dart';
import '../types/Station.dart';
import '../types/playlist_item.dart';
import '../utils/station_ui.dart';

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

  static const double _cardMargin = 4;
  static const double _cardBorder = 1.5;
  static const double _thumbnailSize = 70;
  static const double _titleFontSize = 16;
  static const double _listenersFontSize = 12;

  @override
  Widget build(BuildContext context) {
    final metrics = _RowMetrics.of(context);
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 700,
        mainAxisExtent: metrics.extent,
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
                // TV channels and video-first playlists open the full player
                // straight away so the video is immediately visible; audio/radio
                // stations keep the mini-player-only behavior.
                final panel = panelController;
                if (panel != null &&
                    panel.isAttached &&
                    stationOpensFullPlayerOnTap(station)) {
                  panel.open();
                }
              },
              child: Container(
                margin: const EdgeInsets.symmetric(
                  vertical: _cardMargin,
                  horizontal: 6,
                ),
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
                    width: _cardBorder,
                  ),
                ),
                child: Stack(
                  children: [
                    Row(
                      children: [
                        Container(
                          margin: const EdgeInsets.only(right: 14),
                          width: _thumbnailSize,
                          height: _thumbnailSize,
                          child: ClipRRect(
                            borderRadius:
                                BorderRadius.circular(AppRadius.thumbnail),
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
                                  if (station.stationType !=
                                      StationMediaType.radio) ...[
                                    StationTypeBadge(
                                      type: station.stationType,
                                      compact: true,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Flexible(
                                    child: Text(
                                      station.displayTitle,
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurface,
                                        fontWeight: FontWeight.normal,
                                        fontSize: _titleFontSize,
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
                                height: metrics.subtitleSlot,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  layoutBuilder: (currentChild, previousChildren) => Stack(
                                    alignment: Alignment.centerLeft,
                                    children: [...previousChildren, if (currentChild != null) currentChild],
                                  ),
                                  child: Container(
                                    key: ValueKey('meta-${station.id}-${station.songTitle}-${station.songArtist}'),
                                    alignment: Alignment.centerLeft,
                                    // Only an explicit is_up==false warns; a
                                    // missing/unknown uptime is treated as
                                    // available (see Station.isDown).
                                    child: station.isDown
                                      ? const Text(
                                          "Stație posibil indisponibilă",
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Color(0xFFF87171),
                                            fontSize:
                                                _StationSubtitle._fontSize,
                                          ),
                                        )
                                      : _StationSubtitle(
                                          station: station,
                                          isCurrent: isSelected,
                                        ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: metrics.listenersSlot,
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
                                          Flexible(
                                            child: Text(
                                              '${station.totalListeners} ascultator${station.totalListeners == 1 ? "" : "i"}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                                fontSize: _listenersFontSize,
                                              ),
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

/// Heights in a station row that follow the user's text size.
///
/// The song and listener lines sit in fixed-height slots so a new song or
/// listener count never moves the lines around them. At the default text size
/// the slots are [_subtitleSlot] and [_listenersSlot] tall and the row is as
/// tall as the thumbnail needs. A larger system text size grows each slot to
/// its line and the row to the text, so the text never spills out of the
/// card.
class _RowMetrics {
  const _RowMetrics._({
    required this.extent,
    required this.subtitleSlot,
    required this.listenersSlot,
  });

  factory _RowMetrics.of(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);

    double lineHeight(double fontSize) {
      final painter = TextPainter(
        text: TextSpan(text: ' ', style: style.copyWith(fontSize: fontSize)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final subtitleSlot =
        math.max(_subtitleSlot, lineHeight(_StationSubtitle._fontSize));
    final listenersSlot = math.max(
      _listenersSlot,
      lineHeight(StationsList._listenersFontSize),
    );
    final text = lineHeight(StationsList._titleFontSize) +
        subtitleSlot +
        listenersSlot;
    final content = math.max(StationsList._thumbnailSize, text);
    final edge =
        _contentInset + StationsList._cardBorder + StationsList._cardMargin;
    return _RowMetrics._(
      extent: content + 2 * edge,
      subtitleSlot: subtitleSlot,
      listenersSlot: listenersSlot,
    );
  }

  static const double _subtitleSlot = 22;
  static const double _listenersSlot = 18;

  /// Room above and below the content, as around the thumbnail at the
  /// default text size.
  static const double _contentInset = 12;

  /// Height of a row, margins included.
  final double extent;
  final double subtitleSlot;
  final double listenersSlot;
}

/// Second line of a station row. Typed so stations without a now-playing song
/// never look broken: playlist stations show the current item title when this
/// is the playing station (else a "Listă de redare" label), TV stations show a
/// "Transmisiune live" label, and radio shows its song or, without one,
/// "Live".
class _StationSubtitle extends StatelessWidget {
  const _StationSubtitle({required this.station, required this.isCurrent});

  final Station station;
  final bool isCurrent;

  static const double _fontSize = 13;

  TextStyle _style(BuildContext context) => TextStyle(
        color: Theme.of(context)
            .colorScheme
            .onSurfaceVariant
            .withValues(alpha: 0.7),
        fontSize: _fontSize,
      );

  Widget _line(BuildContext context, String value) => Text(
        value,
        textAlign: TextAlign.left,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _style(context),
      );

  @override
  Widget build(BuildContext context) {
    if (station.isPlaylist) {
      final label = computeStationSubtitle(
            type: StationMediaType.playlist,
            songLine: '',
            isRomanian: true,
            playlistItemCount: station.playlistItems.length,
          ) ??
          '';
      // Only the currently-playing playlist has a "current item"; track it live
      // for that one row so it mirrors the mini/full player.
      if (isCurrent && GetIt.instance.isRegistered<PlaylistController>()) {
        final controller = GetIt.instance<PlaylistController>();
        return StreamBuilder<PlaylistItem?>(
          stream: controller.currentItem.stream,
          initialData: controller.currentItem.valueOrNull,
          builder: (context, snapshot) {
            final title = snapshot.data?.title ?? '';
            return _line(context, title.isNotEmpty ? title : label);
          },
        );
      }
      return _line(context, label);
    }

    // radio / tv
    final songLine = station.songTitle.isNotEmpty
        ? (station.songArtist.isNotEmpty
            ? "${station.songTitle} - ${station.songArtist}"
            : station.songTitle)
        : '';
    final subtitle = computeStationSubtitle(
      type: station.stationType,
      songLine: songLine,
      isRomanian: true,
      tvLiveFallback: true,
    );
    if (subtitle != null && subtitle.isNotEmpty) {
      return _line(context, subtitle);
    }
    return _line(context, "Live");
  }
}
