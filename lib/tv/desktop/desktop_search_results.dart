import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../types/Station.dart';
import '../../utils/romanian_count.dart';
import '../../utils/station_search.dart';
import '../../utils/station_ui.dart';
import '../../widgets/station_type_badge.dart';
import '../tv_theme.dart';
import 'desktop_station_menu.dart';

/// The search results of the desktop screen, as slivers: a header that
/// counts them over their rows, or a line saying there are none.
///
/// The rows show the matched words in bold, in the station's name or its
/// song. They follow the songs as they change: a station whose song stops
/// matching plays its row out ([leaving]), and one whose new song matches
/// grows in ([arriving]).
class DesktopSearchResults extends StatelessWidget {
  const DesktopSearchResults({
    super.key,
    required this.query,
    required this.results,
    required this.highlightedSlug,
    required this.currentSlug,
    required this.playing,
    required this.favoriteSlugs,
    required this.leaving,
    required this.arriving,
    required this.menuSlug,
    required this.rowKey,
    required this.onPlay,
    required this.onHighlight,
    required this.onContextMenu,
    required this.onLeft,
  });

  final String query;
  final List<Station> results;

  /// The row the keyboard highlights, which Enter plays.
  final String? highlightedSlug;

  final String? currentSlug;
  final bool playing;
  final List<String> favoriteSlugs;

  /// The stations whose rows play out.
  final Set<String> leaving;

  /// The stations whose rows grow in.
  final Set<String> arriving;

  /// The station whose menu is open.
  final String? menuSlug;

  /// The key of a station's row, to bring it into view.
  final GlobalKey Function(String slug) rowKey;

  final ValueChanged<Station> onPlay;

  /// The pointer moved onto a station's row.
  final ValueChanged<String> onHighlight;

  final void Function(Station station, Offset globalPosition) onContextMenu;

  /// A station's row played out.
  final ValueChanged<String> onLeft;

  @override
  Widget build(BuildContext context) {
    final shown = results.where((s) => !leaving.contains(s.slug)).length;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final side = math.max(
          DesktopTokens.gutter,
          (width - DesktopTokens.resultsMaxWidth) / 2,
        );
        final padding = EdgeInsets.symmetric(horizontal: side);
        if (results.isEmpty) {
          return SliverPadding(
            padding: padding.copyWith(top: 48, bottom: 48),
            sliver: SliverToBoxAdapter(child: _NoResults(query: query)),
          );
        }
        return SliverMainAxisGroup(
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: SliverToBoxAdapter(child: _Header(count: shown)),
            ),
            SliverPadding(
              padding: padding.copyWith(bottom: 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _row(results[index]),
                  childCount: results.length,
                  findChildIndexCallback: (key) {
                    final index =
                        results.indexWhere((s) => rowKey(s.slug) == key);
                    return index < 0 ? null : index;
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _row(Station station) {
    final String slug = station.slug;
    return _RowTransition(
      key: rowKey(slug),
      arriving: arriving.contains(slug),
      leaving: leaving.contains(slug),
      onLeft: () => onLeft(slug),
      child: DesktopSearchResultRow(
        station: station,
        query: query,
        highlighted: slug == highlightedSlug || slug == menuSlug,
        isCurrent: slug == currentSlug,
        isPlaying: playing,
        isFavorite: favoriteSlugs.contains(slug),
        onPlay: () => onPlay(station),
        onHover: () => onHighlight(slug),
        onContextMenu: (position) => onContextMenu(station, position),
      ),
    );
  }
}

/// "Rezultate" and how many stations were found.
class _Header extends StatelessWidget {
  const _Header({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: DesktopTokens.sectionHeaderHeight,
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Rezultate',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: TvColors.textPrimary,
              ),
            ),
          ),
          Text(
            romanianCount(count, one: 'stație', many: 'stații'),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: TvColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Says no station matches [query], and what the search looks in.
class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(
          Icons.search_off_rounded,
          size: 40,
          color: TvColors.textTertiary,
        ),
        const SizedBox(height: 14),
        Text(
          'Nicio stație găsită pentru „$query”.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: TvColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Caută după numele stației, titlul melodiei sau artist.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: TvColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Grows a row in when it is [arriving] and plays it out, calling [onLeft]
/// once gone, when it is [leaving].
class _RowTransition extends StatefulWidget {
  const _RowTransition({
    super.key,
    required this.arriving,
    required this.leaving,
    required this.onLeft,
    required this.child,
  });

  final bool arriving;
  final bool leaving;
  final VoidCallback onLeft;
  final Widget child;

  @override
  State<_RowTransition> createState() => _RowTransitionState();
}

class _RowTransitionState extends State<_RowTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: DesktopTokens.contentDuration,
    value: widget.arriving ? 0 : 1,
  );

  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void initState() {
    super.initState();
    if (widget.leaving) {
      _leave();
    } else if (widget.arriving) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_RowTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.leaving && !oldWidget.leaving) _leave();
    if (!widget.leaving && oldWidget.leaving) _controller.forward();
  }

  void _leave() {
    _controller.reverse().whenComplete(() {
      if (mounted && widget.leaving) widget.onLeft();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: widget.leaving,
      child: SizeTransition(
        sizeFactor: _curve,
        alignment: Alignment.topLeft,
        child: FadeTransition(opacity: _curve, child: widget.child),
      ),
    );
  }
}

/// A station found by the search: its artwork, its name and its song with
/// the matched words in bold, its heart if a favorite, and "Se redă" on
/// the playing one. Lit while highlighted, by the pointer or the keyboard.
class DesktopSearchResultRow extends StatelessWidget {
  const DesktopSearchResultRow({
    super.key,
    required this.station,
    required this.query,
    required this.highlighted,
    required this.isCurrent,
    required this.isPlaying,
    required this.isFavorite,
    required this.onPlay,
    required this.onHover,
    required this.onContextMenu,
  });

  final Station station;
  final String query;
  final bool highlighted;
  final bool isCurrent;
  final bool isPlaying;
  final bool isFavorite;
  final VoidCallback onPlay;
  final VoidCallback onHover;
  final ValueChanged<Offset> onContextMenu;

  void _onTapUp(TapUpDetails details) {
    // A Control-click opens the menu (DesktopContextClick), not the station.
    if (!kIsWeb &&
        Platform.isMacOS &&
        HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    onPlay();
  }

  @override
  Widget build(BuildContext context) {
    final Color fill;
    if (highlighted) {
      fill = DesktopTokens.controlHoverFill;
    } else if (isCurrent) {
      fill = DesktopTokens.playingFill;
    } else {
      fill = Colors.transparent;
    }
    return Semantics(
      button: true,
      selected: isCurrent,
      label: [
        station.displayTitle,
        if (isCurrent) isPlaying ? 'se redă' : 'în pauză',
        if (station.songLine.isNotEmpty) station.songLine,
      ].join(', '),
      onTap: onPlay,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        // onHover, not onEnter: onEnter also fires when the list scrolls
        // under a still pointer, which would steal the keyboard highlight.
        onHover: (_) => onHover(),
        child: DesktopContextClick(
          onContextClick: onContextMenu,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            child: AnimatedContainer(
              duration: DesktopTokens.hoverDuration,
              height: DesktopTokens.resultRowHeight,
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isCurrent
                      ? DesktopTokens.playingOutline
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox.square(
                      dimension: 48,
                      child: station.displayThumbnail(cacheWidth: 144),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: _RowText(station: station, query: query)),
                  if (isFavorite) ...[
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.favorite_rounded,
                      size: 16,
                      color: TvColors.primary,
                    ),
                  ],
                  if (isCurrent) ...[
                    const SizedBox(width: 10),
                    _PlayingTag(playing: isPlaying),
                  ],
                  const SizedBox(width: 10),
                  AnimatedOpacity(
                    opacity: highlighted ? 1 : 0,
                    duration: DesktopTokens.hoverDuration,
                    child: const Icon(
                      Icons.play_circle_fill_rounded,
                      size: 28,
                      color: TvColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The row's name and song, the parts that match the search in bold.
class _RowText extends StatelessWidget {
  const _RowText({required this.station, required this.query});

  final Station station;
  final String query;

  @override
  Widget build(BuildContext context) {
    final title = station.displayTitle;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (station.stationType != StationMediaType.radio) ...[
              StationTypeBadge(type: station.stationType, compact: true),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: MatchedText(
                text: title,
                matches: stationTitleMatch(title, query),
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: TvColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        AnimatedSwitcher(
          duration: DesktopTokens.contentDuration,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.centerLeft,
            children: [...previous, if (current != null) current],
          ),
          child: KeyedSubtree(
            key: ValueKey('${station.isDown}-${station.songLine}'),
            child: _subtitle(),
          ),
        ),
      ],
    );
  }

  Widget _subtitle() {
    const style = TextStyle(fontSize: 12.5, color: TvColors.textSecondary);
    if (station.isDown) {
      return Text(
        'Stație posibil indisponibilă',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style.copyWith(color: DesktopTokens.warning),
      );
    }
    final songLine = station.isPlaylist ? '' : station.songLine;
    final subtitle = computeStationSubtitle(
          type: station.stationType,
          songLine: songLine,
          isRomanian: true,
          playlistItemCount: station.playlistItems.length,
          tvLiveFallback: true,
        ) ??
        'Live';
    if (songLine.isEmpty) {
      return Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return MatchedText(
      text: subtitle,
      matches: songLineMatch(subtitle, query),
      style: style,
    );
  }
}

/// "Se redă", or "În pauză", on the playing row.
class _PlayingTag extends StatelessWidget {
  const _PlayingTag({required this.playing});

  final bool playing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: TvColors.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        playing ? 'Se redă' : 'În pauză',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: TvColors.primaryLight,
        ),
      ),
    );
  }
}

/// A line of text with the parts that match a search ([matches]) in bold.
class MatchedText extends StatelessWidget {
  const MatchedText({
    super.key,
    required this.text,
    required this.matches,
    required this.style,
  });

  final String text;
  final List<TextRange>? matches;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var end = 0;
    for (final match in matches ?? const <TextRange>[]) {
      if (match.start < end || match.end > text.length) continue;
      spans
        ..add(TextSpan(text: text.substring(end, match.start)))
        ..add(TextSpan(
          text: text.substring(match.start, match.end),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: TvColors.textPrimary,
          ),
        ));
      end = match.end;
    }
    spans.add(TextSpan(text: text.substring(end)));
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
