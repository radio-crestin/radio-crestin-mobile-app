import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../services/announcement.dart';
import '../services/announcement_copy.dart';
import '../services/announcements_service.dart';
import '../theme.dart';
import '../types/Station.dart';
import 'announcement_card.dart';
import 'announcement_icons.dart';

/// A station's announcements and how many of them were never opened.
typedef StationNews = ({List<Announcement> items, int unseen});

/// Rebuilds with the announcements of [station] (placement `station`):
/// [builder] gets none when the station has none.
class StationNewsBuilder extends StatelessWidget {
  const StationNewsBuilder({
    super.key,
    required this.station,
    required this.builder,
  });

  final Station? station;
  final Widget Function(BuildContext context, StationNews news) builder;

  @override
  Widget build(BuildContext context) {
    final getIt = GetIt.instance;
    final slug = station?.slug;
    if (slug == null || !getIt.isRegistered<AnnouncementsService>()) {
      return builder(context, (items: const [], unseen: 0));
    }
    final service = getIt<AnnouncementsService>();
    StationNews news(List<Announcement> _, Set<String> seen) {
      final items = service.forStation(slug);
      return (
        items: items,
        unseen: items.where((item) => !seen.contains(item.slug)).length,
      );
    }

    return StreamBuilder<StationNews>(
      stream:
          Rx.combineLatest2(service.stationAnnouncements, service.seen, news),
      initialData: news(service.stationAnnouncements.value, service.seen.value),
      builder: (context, snapshot) => builder(context, snapshot.requireData),
    );
  }
}

/// The sheet listing the announcements of the station playing, opened
/// from its bell, its unread strip or a push. Opening it marks them seen.
class StationAnnouncementsSheet extends StatelessWidget {
  const StationAnnouncementsSheet({super.key, required this.station});

  final Station station;

  static Future<void> show(BuildContext context, Station station) {
    final service = GetIt.instance<AnnouncementsService>();
    unawaited(service.markSeen(service.forStation(station.slug)));
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).announcementColors.stationSheet,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StationAnnouncementsSheet(station: station),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = GetIt.instance<AnnouncementsService>();
    return StationNewsBuilder(
      station: station,
      builder: (context, news) {
        if (news.items.isEmpty) {
          // The last one was hidden: nothing left to show.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => Navigator.of(context).maybePop());
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(
              14, 8, 14, 26 + MediaQuery.paddingOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Handle(),
              _SheetHeader(station: station),
              Flexible(
                child: SingleChildScrollView(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, item) in news.items.indexed)
                          AnnouncementStaticCard(
                            key: ValueKey(item.slug),
                            item: item,
                            service: service,
                            position: i,
                            station: station.slug,
                            margin: EdgeInsets.only(top: i == 0 ? 0 : 10),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// "Anunțuri ale postului", "De la {station}" and the close button.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.station});

  final Station station;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).announcementColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AnnouncementCopy.stationSheetTitle,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: onSurface,
                  ),
                ),
                Text(
                  AnnouncementCopy.stationSheetSubtitle(station.title),
                  style: TextStyle(
                    fontSize: 13,
                    color: onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Tooltip(
            message: AnnouncementCopy.close,
            child: Material(
              color: colors.backButton,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.of(context).maybePop(),
                child: SizedBox.square(
                  dimension: 36,
                  child: Icon(Icons.close_rounded, size: 16, color: onSurface),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The strip on top of the mini player while the station playing has
/// announcements not opened yet: the first one's title and "nou".
class StationAnnouncementsStrip extends StatelessWidget {
  const StationAnnouncementsStrip({super.key, required this.station});

  final Station? station;

  /// Its height, which the station list keeps clear while it shows.
  static const double height = 40;

  /// Whether [station] has an announcement not opened yet.
  static bool showsFor(Station? station) {
    final getIt = GetIt.instance;
    if (station == null || !getIt.isRegistered<AnnouncementsService>()) {
      return false;
    }
    final service = getIt<AnnouncementsService>();
    final seen = service.seen.value;
    return service
        .forStation(station.slug)
        .any((item) => !seen.contains(item.slug));
  }

  @override
  Widget build(BuildContext context) {
    final current = station;
    return StationNewsBuilder(
      station: current,
      builder: (context, news) {
        final unseen = news.items.where((item) =>
            !GetIt.instance<AnnouncementsService>()
                .seen
                .value
                .contains(item.slug));
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
          child: current == null || news.unseen == 0
              ? const SizedBox(key: ValueKey('none'), width: double.infinity)
              : _Strip(
                  key: ValueKey('strip-${current.slug}'),
                  station: current,
                  first: unseen.first,
                ),
        );
      },
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({super.key, required this.station, required this.first});

  final Station station;
  final Announcement first;

  @override
  Widget build(BuildContext context) {
    final mini =
        Theme.of(context).bottomAppBarTheme.color ?? AppColors.playerBarLight;
    final background = Color.lerp(mini, Colors.white, 0.18)!;
    final icon =
        announcementIcons[first.iconName] ?? announcementIcons['megaphone']!;
    return Semantics(
      button: true,
      label: AnnouncementCopy.bellLabel,
      child: Material(
        color: background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('station-announcements-strip'),
          onTap: () => StationAnnouncementsSheet.show(context, station),
          child: SizedBox(
            height: StationAnnouncementsStrip.height,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 10),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: first.category.color,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(
                      icon,
                      size: 14 * announcementIconScale(icon),
                      color: first.category.textColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      first.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      AnnouncementCopy.newBadge,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: mini,
                      ),
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

/// Where a station's bell sits: on the mini player, or in the full
/// player's header.
enum StationBellPlace { miniPlayer, fullPlayer }

/// A bell with the number of the station's announcements; it opens their
/// sheet. Nothing when the station has none.
class StationAnnouncementsBell extends StatelessWidget {
  const StationAnnouncementsBell({
    super.key,
    required this.station,
    required this.place,
  });

  final Station? station;
  final StationBellPlace place;

  /// Whether [station] has announcements, so a bell shows.
  static bool showsFor(Station? station) {
    final getIt = GetIt.instance;
    if (station == null || !getIt.isRegistered<AnnouncementsService>()) {
      return false;
    }
    return getIt<AnnouncementsService>().forStation(station.slug).isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final current = station;
    return StationNewsBuilder(
      station: current,
      builder: (context, news) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: current == null || news.items.isEmpty
            ? const SizedBox.shrink(key: ValueKey('no-bell'))
            : place == StationBellPlace.miniPlayer
                ? _MiniBell(
                    key: ValueKey('bell-${current.slug}'),
                    count: news.items.length,
                    onTap: () =>
                        StationAnnouncementsSheet.show(context, current),
                  )
                : _PlayerBell(
                    key: ValueKey('bell-${current.slug}'),
                    count: news.items.length,
                    onTap: () =>
                        StationAnnouncementsSheet.show(context, current),
                  ),
      ),
    );
  }
}

/// The mini player's 38 px round bell, white on the bar.
class _MiniBell extends StatelessWidget {
  const _MiniBell({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mini =
        Theme.of(context).bottomAppBarTheme.color ?? AppColors.playerBarLight;
    return Tooltip(
      message: AnnouncementCopy.bellLabel,
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        shape: const CircleBorder(),
        child: InkWell(
          key: const ValueKey('station-announcements-bell'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 38,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                const Icon(Icons.notifications_none_rounded,
                    size: 19, color: Colors.white),
                Positioned(
                  top: 2,
                  right: 1,
                  child: _Badge(
                    count: count,
                    background: Colors.white,
                    foreground: mini,
                    ring: mini,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The full player's bell, beside the cast button.
class _PlayerBell extends StatelessWidget {
  const _PlayerBell({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        key: const ValueKey('station-announcements-player-bell'),
        tooltip: AnnouncementCopy.bellLabel,
        onPressed: onTap,
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.notifications_none_rounded, size: 22, color: onSurface),
            Positioned(
              top: -5,
              right: -7,
              child: _Badge(
                count: count,
                background: AppColors.primary,
                foreground: Colors.white,
                ring: Theme.of(context).scaffoldBackgroundColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.count,
    required this.background,
    required this.foreground,
    required this.ring,
  });

  final int count;
  final Color background;
  final Color foreground;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16),
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: ring, spreadRadius: 2)],
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 10.5,
          height: 1,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}
