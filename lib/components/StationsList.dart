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
import '../widgets/hide_station_dialog.dart';
import '../widgets/re_add_station_button.dart';
import '../widgets/share_sheet.dart';
import '../widgets/station_actions_menu.dart';
import '../widgets/station_reorder.dart';
import '../widgets/station_row_transition.dart';

class StationsList extends StatelessWidget {
  const StationsList({
    super.key,
    required this.stations,
    required this.audioHandler,
    required this.panelController,
    required this.favoriteSlugs,
    this.currentStation,
    this.isFavoritesList = false,
    this.onStationHidden,
    this.rowTransitions,
    this.reorder,
    this.shownHidden,
    this.hidesInPlace = false,
    this.onShowHidden,
  });

  final Station? currentStation;
  final List<Station> stations;
  final AppAudioHandler audioHandler;
  final PanelController? panelController;
  final List<String> favoriteSlugs;
  final bool isFavoritesList;

  /// Called once the listener hid a station from its long-press menu;
  /// [favoriteIndex]: the place it had among the favorites, which hiding
  /// took it out of.
  final void Function(Station station, int? favoriteIndex)? onStationHidden;

  /// Plays a hidden station's rows out before it leaves the list, and an
  /// undone one's back in. Shared by every list of the page, so all the
  /// rows of a station move together. Without it rows leave at once.
  final StationRowTransitions? rowTransitions;

  /// Lets the listener arrange the rows: held, a row follows the finger to
  /// another place in the list. Null where rows keep the list's order.
  final StationReorder? reorder;

  /// The hidden stations among [stations], each listed in its place,
  /// dimmed, with a button that adds it back ([onShowHidden]). A row fades
  /// from one look to the other as its station is hidden or added back.
  /// Null where the list never shows hidden stations.
  final Set<String>? shownHidden;

  /// Whether a station hidden here dims in its place rather than playing
  /// its row out: [shownHidden] will list it.
  final bool hidesInPlace;

  /// Adds back a hidden station listed in its place.
  final ValueChanged<Station>? onShowHidden;

  /// Rows are at most this wide: wider lists show a grid.
  static const double _maxRowWidth = 700;

  static const double _cardMargin = 4;

  /// Around a row's card, within its slot.
  static const EdgeInsets _cardInset =
      EdgeInsets.symmetric(vertical: _cardMargin, horizontal: 6);

  static const double _cardBorder = 1.5;
  static const double _thumbnailSize = 70;
  static const double _titleFontSize = 16;
  static const double _listenersFontSize = 12;

  void _toggleFavorite(Station station, {required String source}) {
    final isFavorite = audioHandler.toggleStationFavorite(station);
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'favorite_toggle',
      'station_slug': station.slug,
      'station_id': station.id,
      'is_favorite': isFavorite,
      'source': source,
    });
  }

  void _share(BuildContext context, Station station) {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'station_menu_share',
      'station_slug': station.slug,
      'station_id': station.id,
    });
    ShareSheet.showForStation(
      context,
      station: station,
      client: audioHandler.graphqlClient,
    );
  }

  bool _isFavorite(Station station) => audioHandler
      .stationDataService.favoriteStationSlugs.value
      .contains(station.slug);

  /// A favorite is hidden only once the listener agreed to lose it from
  /// the favorites.
  Future<bool> _confirmHide(BuildContext context, Station station) async =>
      !_isFavorite(station) ||
      await confirmHideFavoriteStation(context, station);

  /// Plays the station's rows out, then hides it.
  void _hide(Station station) {
    final wasFavorite = _isFavorite(station);
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'station_hide',
      'station_slug': station.slug,
      'station_id': station.id,
      'was_favorite': wasFavorite,
      'from_favorites': isFavoritesList,
    });
    void hide() {
      final favoriteIndex = audioHandler.hideStation(station);
      onStationHidden?.call(station, favoriteIndex);
    }

    final transitions = rowTransitions;
    if (transitions == null || hidesInPlace) {
      hide();
    } else {
      transitions.leave(station.slug, hide);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reorder = this.reorder;
    if (reorder == null) return _buildList(context, stations, order: null);
    // A row just moved shows in its new place at once, as it lands, though
    // [stations] take that order only once it is saved.
    return ListenableBuilder(
      listenable: reorder,
      builder: (context, _) {
        final shown = reorder.ordered(stations, _slugOf);
        return _buildList(context, shown,
            order: [for (final station in shown) _slugOf(station)]);
      },
    );
  }

  static String _slugOf(Station station) => station.slug;

  /// The rows of [stations]; [order] is their slugs where the listener can
  /// arrange them.
  Widget _buildList(
    BuildContext context,
    List<Station> stations, {
    required List<String>? order,
  }) {
    final metrics = _RowMetrics.of(context);
    final indexByKey = {
      for (final (index, station) in stations.indexed)
        _rowKey(station): index,
    };
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // One column, as on a phone: a list, where a hidden station's slot
        // can close. In a grid the other tiles can't slide into it.
        final oneColumn = constraints.crossAxisExtent <= _maxRowWidth;
        final delegate = SliverChildBuilderDelegate(
          (context, index) => _buildRow(
            context,
            stations[index],
            metrics,
            collapses: oneColumn,
            order: order,
          ),
          childCount: stations.length,
          // A row keeps its state when the rows around it change, so one
          // sliding up into a closed slot isn't built anew.
          findChildIndexCallback: (key) => indexByKey[key],
        );
        if (oneColumn) return SliverList(delegate: delegate);
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _maxRowWidth,
            mainAxisExtent: metrics.extent,
          ),
          delegate: delegate,
        );
      },
    );
  }

  static Key _rowKey(Station station) => ValueKey('station-${station.slug}');

  Widget _buildRow(
    BuildContext context,
    Station station,
    _RowMetrics metrics, {
    required bool collapses,
    required List<String>? order,
  }) {
          final isSelected = station.slug == currentStation?.slug;
          final reorder = this.reorder;
          final String slug = station.slug;
          final index = order?.indexOf(slug) ?? -1;

          // Moves the row [by] places, for screen readers; null where it
          // can't go.
          VoidCallback? moveBy(int by) {
            final to = index + by;
            if (reorder == null ||
                order == null ||
                index < 0 ||
                to < 0 ||
                to >= order.length) {
              return null;
            }
            return () => reorder.move(order, slug, by);
          }

          final card = Container(
                padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                    ? Theme.of(context).cardColorSelected
                    : Theme.of(context).cardColor,
                  borderRadius: const BorderRadius.all(Radius.circular(16.0)),
                  // In the light theme the deeper fill alone marks the
                  // playing station; the border keeps its width either way
                  // so the content never shifts.
                  border: Border.all(
                    color: isSelected &&
                            Theme.of(context).brightness == Brightness.dark
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
                          HapticFeedback.lightImpact();
                          _toggleFavorite(station, source: 'heart');
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
              );

          Widget rowWith(StationRowDrag? drag) => SizedBox(
            height: metrics.extent,
            child: StationActionsMenu(
            isFavorite: favoriteSlugs.contains(station.slug),
            onToggleFavorite: () =>
                _toggleFavorite(station, source: 'station_menu'),
            onShare: () => _share(context, station),
            confirmHide: () => _confirmHide(context, station),
            onHide: () => _hide(station),
            drag: drag,
            onMoveUp: moveBy(-1),
            onMoveDown: moveBy(1),
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
              child: Padding(padding: _cardInset, child: card),
            )));

    // Only a list of one column moves a row by hand: a grid can't slide
    // its tiles out of the way.
    Widget row = reorder == null || order == null || !collapses
        ? rowWith(null)
        : StationReorderSlot(
            reorder: reorder,
            slug: slug,
            order: order,
            lifted: (context, lift) => _LiftedCard(card: card, lift: lift),
            builder: (context, drag) => rowWith(drag),
          );
    final shownHidden = this.shownHidden;
    if (shownHidden != null) {
      final hidden = shownHidden.contains(slug);
      row = AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        switchInCurve: Curves.easeInOut,
        switchOutCurve: Curves.easeInOut,
        child: KeyedSubtree(
          key: ValueKey(hidden),
          child: hidden
              ? SizedBox(
                  height: metrics.extent,
                  child: Padding(
                    padding: _cardInset,
                    child: _HiddenStationCard(
                      station: station,
                      onShow: () => onShowHidden?.call(station),
                    ),
                  ),
                )
              : row,
        ),
      );
    }

    final transitions = rowTransitions;
    return KeyedSubtree(
      key: _rowKey(station),
      child: RepaintBoundary(
        child: transitions == null
            ? row
            : StationRowTransition(
                slug: station.slug,
                transitions: transitions,
                collapses: collapses,
                child: row,
              ),
      ),
    );
  }
}

/// A hidden station listed in its place: its row dimmed and marked hidden,
/// with a button that adds it back. It plays nothing and has no menu.
class _HiddenStationCard extends StatelessWidget {
  const _HiddenStationCard({required this.station, required this.onShow});

  final Station station;
  final VoidCallback onShow;

  static const String hiddenLabel = 'Ascunsă';

  /// How much of the logo shows through.
  static const double _logoOpacity = 0.35;
  static const double _badgeSize = 26;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        border: Border.all(
          color: Colors.transparent,
          width: StationsList._cardBorder,
        ),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Opacity(
                  opacity: _logoOpacity,
                  child: SizedBox.square(
                    dimension: StationsList._thumbnailSize,
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.circular(AppRadius.thumbnail),
                      child: station.thumbnail,
                    ),
                  ),
                ),
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: Container(
                    width: _badgeSize,
                    height: _badgeSize,
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.visibility_off_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Semantics(
              label: '${station.displayTitle}, ${hiddenLabel.toLowerCase()}',
              excludeSemantics: true,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    station.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                      fontSize: StationsList._titleFontSize,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hiddenLabel,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      fontSize: _StationSubtitle._fontSize,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // On the grey card, a white pill reads as the one thing to tap.
          ReAddStationButton(
            onPressed: onShow,
            fill: dark ? null : scheme.surface,
          ),
        ],
      ),
    );
  }
}

/// A row's card as it follows the finger that moves it: lifted, it casts a
/// shadow, and it is opaque, as the rows it passes show through a card.
class _LiftedCard extends StatelessWidget {
  const _LiftedCard({required this.card, required this.lift});

  final Widget card;

  /// From 0, in the list, to 1, lifted.
  final double lift;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shadow = theme.brightness == Brightness.dark
        ? AppColors.liftedRowShadowDark
        : AppColors.liftedRowShadow;
    return Padding(
      padding: StationsList._cardInset,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: shadow.withValues(alpha: shadow.a * lift),
              blurRadius: 18 * lift,
              offset: Offset(0, 6 * lift),
            ),
          ],
        ),
        child: card,
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
