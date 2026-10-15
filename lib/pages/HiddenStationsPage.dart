import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

import '../appAudioHandler.dart';
import '../main.dart' show getIt;
import '../services/analytics_service.dart';
import '../services/station_data_service.dart';
import '../theme.dart';
import '../types/Station.dart';
import '../utils/romanian_count.dart';
import '../widgets/pinned_title_sliver_header.dart';

/// The stations the listener hid, last hidden first, each with a button
/// that adds it back to the lists. Without any, it tells how to hide one.
class HiddenStationsPage extends StatefulWidget {
  const HiddenStationsPage({super.key});

  /// Pushes the page onto the navigation stack.
  static void show(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        // Named so PostHog records a `$screen` for it.
        settings: const RouteSettings(name: '/hidden-stations'),
        builder: (_) => const HiddenStationsPage(),
      ),
    );
  }

  /// "3 stații ascunse", for the settings row that opens this page.
  static String countText(int count) => count == 0
      ? 'Nicio stație ascunsă'
      : romanianCount(count, one: 'stație ascunsă', many: 'stații ascunse');

  @override
  State<HiddenStationsPage> createState() => _HiddenStationsPageState();
}

class _HiddenStationsPageState extends State<HiddenStationsPage> {
  final StationDataService _stationDataService = getIt<StationDataService>();
  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();
  StreamSubscription<List<Station>>? _subscription;
  late List<Station> _stations = _stationDataService.hiddenStations;

  @override
  void initState() {
    super.initState();
    _subscription = Rx.combineLatest2(
      _stationDataService.stations.stream,
      _stationDataService.hiddenStationSlugs.stream,
      (_, __) => _stationDataService.hiddenStations,
    ).listen((stations) {
      if (mounted) setState(() => _stations = stations);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _show(Station station) {
    HapticFeedback.lightImpact();
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'station_unhide',
      'source': 'settings',
      'station_id': station.id,
      'station_slug': station.slug,
    });
    unawaited(_audioHandler.unhideStation(station));
  }

  @override
  Widget build(BuildContext context) {
    final stations = _stations;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const PinnedTitleSliverHeader(title: 'Stații ascunse'),
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              // Out, then in: the list fades away whole, its last station
              // still on it, before the empty page fades in, both from the
              // top, so nothing shows alone or jumps on the way.
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: const Interval(0.5, 1, curve: Curves.easeOut),
                switchOutCurve: const Interval(0.5, 1, curve: Curves.easeIn),
                layoutBuilder: _stackFromTop,
                child: stations.isEmpty
                    ? const _EmptyState()
                    : _HiddenList(
                        key: const ValueKey('list'),
                        stations: stations,
                        onShow: _show,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _stackFromTop(Widget? current, List<Widget> previous) => Stack(
      alignment: Alignment.topCenter,
      children: [...previous, if (current != null) current],
    );

/// The colors of the settings page's grouped cards, in the current theme.
class _Grouped {
  _Grouped.of(BuildContext context)
      : dark = Theme.of(context).brightness == Brightness.dark;

  final bool dark;

  Color get card => dark ? AppColors.groupedCardDark : AppColors.groupedCard;
  Color get text => dark ? AppColors.groupedTextDark : AppColors.groupedText;
  Color get secondary => dark
      ? AppColors.groupedTextSecondaryDark
      : AppColors.groupedTextSecondary;
  Color get divider =>
      dark ? AppColors.groupedDividerDark : AppColors.groupedDivider;
  Color get action =>
      dark ? AppColors.groupedAction : AppColors.groupedActionOnLight;

  /// The "Readaugă" pill. Dark: the neutral capsule of the player's sheets
  /// (sleep timer, share), white on white at 13%, so the logos stay the
  /// colorful part of the row. Light: [action] on a tint of it, faint
  /// enough for the text to keep 4.5:1 contrast.
  Color get buttonFill => dark
      ? AppColors.darkText.withValues(alpha: 0.13)
      : action.withValues(alpha: 0.08);
  Color get buttonText => dark ? AppColors.darkText : action;
}

/// Where a hidden station no longer shows, for the page's explanation.
String _whereHidden(BuildContext context) {
  final car = switch (Theme.of(context).platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => 'CarPlay',
    _ => 'Android Auto',
  };
  return 'Stațiile ascunse nu apar în lista de stații, la Favorite, în '
      'căutare și nici în $car.';
}

class _HiddenList extends StatelessWidget {
  const _HiddenList({
    super.key,
    required this.stations,
    required this.onShow,
  });

  final List<Station> stations;
  final ValueChanged<Station> onShow;

  @override
  Widget build(BuildContext context) {
    final colors = _Grouped.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text(
            _whereHidden(context),
            style: TextStyle(fontSize: 14, height: 1.4, color: colors.secondary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: colors.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (index, station) in stations.indexed)
                  _HiddenStationRow(
                    key: ValueKey(station.slug),
                    station: station,
                    showDivider: index < stations.length - 1,
                    foldsAway: stations.length > 1,
                    onShow: () => onShow(station),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

/// A hidden station: its logo and name, and "Readaugă", which folds the row
/// away before the station goes back to the lists ([foldsAway]).
///
/// The last one doesn't fold: the whole list fades into the empty page
/// instead, which would otherwise follow a moment of the page's text alone.
class _HiddenStationRow extends StatefulWidget {
  const _HiddenStationRow({
    super.key,
    required this.station,
    required this.showDivider,
    required this.foldsAway,
    required this.onShow,
  });

  final Station station;

  /// Whether a hairline separates it from the row below.
  final bool showDivider;

  /// Whether "Readaugă" folds the row away before showing the station.
  final bool foldsAway;

  final VoidCallback onShow;

  @override
  State<_HiddenStationRow> createState() => _HiddenStationRowState();
}

class _HiddenStationRowState extends State<_HiddenStationRow>
    with SingleTickerProviderStateMixin {
  static const _thumbnailSize = 44.0;

  late final AnimationController _leave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _size = CurvedAnimation(
    parent: ReverseAnimation(_leave),
    curve: Curves.easeInOut,
  );

  /// Whether "Readaugă" was tapped, so a second tap does nothing.
  bool _showing = false;

  @override
  void dispose() {
    _leave.dispose();
    super.dispose();
  }

  Future<void> _show() async {
    if (_showing) return;
    _showing = true;
    if (widget.foldsAway) await _leave.forward();
    if (mounted) widget.onShow();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _Grouped.of(context);
    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: _size,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox.square(
                      dimension: _thumbnailSize,
                      child: widget.station.logo,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.station.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: colors.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ReAddButton(onPressed: _show),
                ],
              ),
            ),
            if (widget.showDivider)
              Padding(
                padding: const EdgeInsets.only(left: 12 + _thumbnailSize + 12),
                child: Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: colors.divider,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "+ Readaugă", a pill that says the station goes back to the lists: the
/// plus for adding, as "Afișează" alone said nothing of where to.
class _ReAddButton extends StatelessWidget {
  const _ReAddButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = _Grouped.of(context);
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('Readaugă'),
      style: TextButton.styleFrom(
        foregroundColor: colors.buttonText,
        backgroundColor: colors.buttonFill,
        shape: const StadiumBorder(),
        minimumSize: const Size(0, 34),
        padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 14, 0),
        // The pill is 34 high, its touch area the full 48.
        tapTargetSize: MaterialTapTargetSize.padded,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// No hidden station: how to hide one.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = _Grouped.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 40),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: colors.card,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.visibility_off_outlined,
              size: 32,
              color: colors.secondary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Nicio stație ascunsă',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Ține apăsat pe o stație din listă și alege „Ascunde stația”. '
            '${_whereHidden(context)} Le poți readăuga oricând de aici.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.45, color: colors.secondary),
          ),
        ],
      ),
    );
  }
}
