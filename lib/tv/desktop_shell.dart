import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../appAudioHandler.dart';
import '../globals.dart' as globals;
import '../pages/SettingsPage.dart';
import '../queries/getStations.graphql.dart';
import '../services/analytics_service.dart';
import '../services/desktop_menu_service.dart';
import '../services/mac_app_store_updates.dart';
import '../services/station_data_service.dart';
import '../services/station_group_categories.dart';
import '../services/station_sort_service.dart';
import '../types/Station.dart';
import '../utils.dart';
import '../utils/station_search.dart';
import '../widgets/animated_play_button.dart';
import 'desktop/desktop_browse_model.dart';
import 'desktop/desktop_category_bar.dart';
import 'desktop/desktop_mini_player.dart';
import 'desktop/desktop_now_playing_route.dart';
import 'desktop/desktop_play_history.dart';
import 'desktop/desktop_recent_stations.dart';
import 'desktop/desktop_search_field.dart';
import 'desktop/desktop_search_results.dart';
import 'desktop/desktop_sections.dart';
import 'desktop/desktop_shortcuts.dart';
import 'desktop/desktop_smooth_scroll.dart';
import 'desktop/desktop_sort_menu.dart';
import 'desktop/desktop_station_actions.dart';
import 'desktop/desktop_station_card.dart';
import 'desktop/desktop_station_menu.dart';
import 'desktop/desktop_update_dialog.dart';
import 'desktop/desktop_volume_control.dart';
import 'desktop/desktop_window_drag_area.dart';
import 'desktop/settings_links.dart';
import 'desktop/settings_panel.dart';
import 'desktop_now_playing_sheet.dart';
import 'tv_lifecycle.dart';
import 'tv_shell.dart';
import 'tv_theme.dart';
import 'tv_youtube_auto_advance.dart';

/// The desktop app (macOS, Windows, Linux): the stations to browse, with
/// the search in the top bar, and the mini player at the bottom, which
/// opens "Se redă acum" over the window.
///
/// It works like the phone's home page: a "Favorite" section above every
/// station or the chosen category's, the same sort orders, the search that
/// also finds stations by the song playing, and the hidden stations left
/// out. For the mouse and keyboard it adds hover states, a context menu on
/// every station, and the keyboard shortcuts of the macOS menu bar, whose
/// commands it carries out ([DesktopMenuService]).
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.youtubeCountdown,
    this.updates,
    this.now = DateTime.now,
  });

  /// The YouTube auto-advance of the enclosing [TvShell], for the sheet.
  final ValueListenable<TvYoutubeCountdown?> youtubeCountdown;

  /// Asks the Mac App Store for a newer version. Left out, a build that
  /// asks (see `_checksForUpdates`) makes its own; a test gives one that
  /// asks a stand-in store.
  final MacAppStoreUpdates? updates;

  /// The time, for how long the window was left; a test moves it on.
  final DateTime Function() now;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  late final AppAudioHandler _audioHandler;
  late final StationDataService _data;
  late final DesktopStationActions _actions;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  late final FocusScopeNode _scope = FocusScopeNode(
    debugLabel: 'DesktopShell',
    onKeyEvent: _onKey,
  );
  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'DesktopSearch');
  final ScrollController _scroll = DesktopScrollController();
  final MenuController _sortMenu = MenuController();
  final GlobalKey<DesktopStationMenuState> _menu = GlobalKey();
  final GlobalKey<AnimatedPlayButtonState> _playButton = GlobalKey();

  /// The search results as the songs change under them.
  final LiveSearchResults _liveResults = LiveSearchResults();

  /// The keys of the search results' rows, to bring the highlighted one
  /// into view.
  final Map<String, GlobalKey> _resultKeys = {};

  ModalRoute<dynamic>? _route;
  Route<void>? _nowPlayingRoute;

  Station? _currentStation;
  bool _playing = false;
  List<String> _favoriteSlugs = const [];
  List<Query$GetStations$station_groups> _groups = const [];
  Query$GetStations$station_groups? _selectedGroup;

  /// The category the grid lists. It follows [_selectedGroup] once the
  /// service has filtered that category's stations, a moment later: the
  /// chips answer a click at once, while the grid's title, count and cards
  /// change together, never the new title over the old stations.
  Query$GetStations$station_groups? _listedGroup;
  StationSortOption _sortOption = StationSortOption.recommended;

  /// Whether the catalog arrived: until then the screen says it loads.
  bool _catalogLoaded = false;

  /// How many stations the listener can see, the hidden ones aside.
  int _visibleCount = 0;

  DesktopBrowseContent _content = const DesktopBrowseContent();
  StationGroupCategories _categories = const StationGroupCategories(
    categories: [],
    stationCount: 0,
    listenerCount: 0,
  );

  /// The category whose hidden stations the grid shows in their places,
  /// dimmed: one chosen with all its stations hidden. They stay while it
  /// is chosen, as some are added back.
  int? _hiddenShownInGroup;

  String _query = '';
  List<Station> _results = const [];
  Set<String> _leaving = const {};
  final Set<String> _arriving = {};
  String? _highlightSlug;

  /// Where the station list was scrolled when a search started, to go
  /// back there once it ends.
  double? _offsetBeforeSearch;

  /// The station whose context menu is open, which its card shows.
  String? _menuSlug;

  /// What the menu bar was last told, so it isn't told twice; `recent`
  /// is the offered stations' slugs and titles, joined.
  ({
    bool hasStation,
    bool playing,
    bool isFavorite,
    bool muted,
    String recent
  })? _menuBarState;

  /// The stations last listened to, for the Dock menu.
  late final DesktopRecentStations _recent;

  /// The stations played, for the mouse's back and forward buttons; back
  /// reaches the ones listened to before the launch too.
  late final DesktopPlayHistory _played;

  /// The cards' keys, by station and section (a favorite has a card in
  /// both), to tell where a card is and how many columns its grid has.
  final Map<({String slug, bool inFavorites}), GlobalKey> _cardKeys = {};

  /// The station list, whose bounds tell which cards are in view.
  final GlobalKey _listKey = GlobalKey(debugLabel: 'DesktopList');

  /// Whether an arrow asked for another station, whose card is then
  /// brought into view as it plays: the arrows go through the grid. The
  /// player bar's buttons and the menus leave the list where it is.
  bool _revealSkippedTo = false;

  /// When the Mac App Store is next asked for a newer version.
  Timer? _updateCheck;

  /// When the image cache on disk is next cleared of old song art, as the
  /// phone's home page does at launch; again every
  /// [_imageCachePruneInterval], as the app may stay open for days.
  Timer? _imageCachePrune;
  static const Duration _imageCachePruneInterval = Duration(hours: 12);

  /// How often the Mac App Store is asked, as the app may stay open for
  /// days.
  static const Duration _updateCheckInterval = Duration(hours: 12);

  /// Asks the Mac App Store, from the first check on.
  late final MacAppStoreUpdates _updates = widget.updates ??
      MacAppStoreUpdates(
        prefs: GetIt.instance<SharedPreferences>(),
        currentVersion: globals.appVersion,
      );

  /// A newer version found while a panel or a dialog covered the shell,
  /// kept to offer once that closes rather than asking the store again.
  MacAppStoreRelease? _pendingUpdate;

  /// Whether the update dialog is up, so a check meanwhile doesn't offer
  /// the same version again once it is answered.
  bool _offeringUpdate = false;

  /// Offers [_pendingUpdate] once what covered the shell has closed.
  Timer? _updateOffer;

  /// How long a closing panel or dialog takes to leave ("Se redă acum"
  /// shrinks back for 300 ms), for the update dialog to open after it
  /// rather than over it.
  static const Duration _offerAfterClosing = Duration(milliseconds: 350);

  /// Tells the window coming back into sight from a mere change of the
  /// active window, as the [TvShell] does.
  final TvLifecycleTracker _lifecycleTracker =
      TvLifecycleTracker(hiddenIsBackground: true);
  late final AppLifecycleListener _lifecycle;

  /// Since when the listener has left the window: another app active, or
  /// the window out of sight. Null while it is in use.
  DateTime? _leftAt;

  /// How long the window is left before, back in sight, the user-chosen
  /// order is made again from the current numbers.
  static const Duration _chosenOrderKeptFor = Duration(minutes: 30);

  /// Whether the user-chosen order is to be made again, the window having
  /// been left for [_chosenOrderKeptFor]: as it shows again if the numbers
  /// are fresh, else with the numbers the sync it starts brings.
  bool _remakeDue = false;

  /// Whether nothing was pressed in the window since it came back into
  /// sight: until then a new order moves no card from under a click.
  bool _untouchedSinceReturn = false;

  /// When the stations last changed: while the window is hidden and
  /// nothing plays, no sync runs, and the numbers grow old.
  DateTime? _stationsChangedAt;

  /// How recent the numbers must be to make the order from them as the
  /// window shows again.
  static const Duration _freshNumbers = Duration(minutes: 2);

  /// Whether this build asks the Mac App Store for updates: a release on a
  /// Mac, or any build previewing the dialog (see
  /// [MacAppStoreUpdates.previewVersion]).
  static bool get _checksForUpdates =>
      !kIsWeb &&
      Platform.isMacOS &&
      (kReleaseMode || MacAppStoreUpdates.previewVersion.isNotEmpty);

  /// What the browser-style back closed, the latest last, for forward to
  /// bring back. Opening something else forgets it, as a browser does.
  final List<_BackStep> _forwardSteps = [];

  /// Set while back or forward moves around, so that the moves they make
  /// through the usual paths don't forget [_forwardSteps].
  bool _steppingThroughHistory = false;

  bool get _searching => _query.isNotEmpty;

  /// Whether the search field shows in the top bar, in place of its search
  /// button: from a click on the button (or ⌘F) until the field is left
  /// with nothing typed.
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    _audioHandler = GetIt.instance<AppAudioHandler>();
    _data = GetIt.instance<StationDataService>();
    _actions = DesktopStationActions(_audioHandler);
    _recent = DesktopRecentStations(GetIt.instance<SharedPreferences>());
    _played = DesktopPlayHistory(earlier: _recent.slugs.reversed);
    _sortOption = StationSortService.loadSavedSort();

    // Seeded from the streams' values, so the first frame shows the
    // stations instead of an empty screen.
    _currentStation = _audioHandler.currentStation.valueOrNull;
    _playing = _audioHandler.playbackState.value.playing;
    _favoriteSlugs = _data.favoriteStationSlugs.value;
    _groups = _data.stationGroups.value;
    _selectedGroup = _data.selectedStationGroup.value;
    _listedGroup = _selectedGroup;
    _recompute();
    _syncMenuBar();
    _searchFocus.addListener(_updateSearchOpen);

    _subscriptions
      // The list stays where the listener left it as another station
      // comes on (a skip, the menus, the Dock, media keys): the player bar
      // shows what plays.
      ..add(_audioHandler.currentStation.stream.listen((station) {
        if (!mounted) return;
        if (station != null) {
          _recent.add(station.slug);
          _played.played(station.slug);
          // Not as the station playing is sent again with its new song.
          if (_revealSkippedTo && station.slug != _currentStation?.slug) {
            _revealSkippedTo = false;
            final String slug = station.slug;
            // Once the grid shows it as playing.
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _revealCard(slug));
          }
        }
        setState(() => _currentStation = station);
        _syncMenuBar();
      }))
      ..add(_audioHandler.playbackState.stream.listen((state) {
        // The state is broadcast again on every position tick; the screen
        // only shows whether it plays.
        if (!mounted || state.playing == _playing) return;
        setState(() => _playing = state.playing);
        _syncMenuBar();
      }))
      // Follows the stations, the hidden ones and the chosen category.
      ..add(_data.filteredStations.stream.listen((_) {
        _stationsChangedAt = widget.now();
        _listedGroup = _data.selectedStationGroup.value;
        _remakeChosenOrderIfDue();
        _refresh();
      }))
      ..add(_data.favoriteStationSlugs.stream.listen((slugs) {
        _favoriteSlugs = slugs;
        _refresh();
        _syncMenuBar();
      }))
      ..add(_data.stationGroups.stream.listen((groups) {
        _groups = groups;
        _refresh();
      }))
      ..add(_data.selectedStationGroup.stream.listen((group) {
        _selectedGroup = group;
        _refresh();
      }))
      // For the menu bar's mute item, which only tells muted from not: not
      // at every step of a dragged volume slider.
      ..add(_audioHandler.listenerVolume.stream
          .map((volume) => volume == 0)
          .distinct()
          .listen((_) => _syncMenuBar()))
      ..add(DesktopMenuService.commands.listen(_onCommand))
      ..add(DesktopMenuService.stationRequests.listen(_playRequested));
    // Every press anywhere in the window, over dialogs too.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChanged);
    // Well after launch, once the stations and the first images are in.
    _imageCachePrune =
        Timer(const Duration(seconds: 30), _pruneImageDiskCache);
    // A few seconds after launch, once the screen has settled.
    if (widget.updates != null || _checksForUpdates) {
      _updateCheck = Timer(const Duration(seconds: 4), _checkForUpdate);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Also called as a panel or a dialog over the shell closes, as the
    // route becomes current again.
    _route = ModalRoute.of(context);
    if (_pendingUpdate != null && _route?.isCurrent == true) {
      _updateOffer?.cancel();
      _updateOffer = Timer(_offerAfterClosing, _offerPendingUpdate);
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _lifecycle.dispose();
    _updateCheck?.cancel();
    _imageCachePrune?.cancel();
    _updateOffer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _scope.dispose();
    _searchText.dispose();
    _searchFocus
      ..removeListener(_updateSearchOpen)
      ..dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ─── Data ───

  void _refresh() {
    if (mounted) setState(_recompute);
  }

  /// Works out the sections, the categories and the search results from
  /// the station data, as the phone's home page does.
  void _recompute() {
    _catalogLoaded = _catalogLoaded || _data.stations.value.isNotEmpty;
    final visible = _data.visibleStations;
    _visibleCount = visible.length;
    _categories = _withChosen(
      desktopCategoryOffer(
        StationGroupCategories.compute(groups: _groups, stations: visible),
      ),
      _selectedGroup,
    );

    final group = _listedGroup;
    final listed = _data.getSortedStations();
    // The service gives the hidden ones of the category just chosen.
    final withHidden = group == null || group.id != _selectedGroup?.id
        ? const <Station>[]
        : _data.getSortedGroupStationsWithHidden();
    if (group?.id != _hiddenShownInGroup) _hiddenShownInGroup = null;
    if (group != null && listed.isEmpty && withHidden.isNotEmpty) {
      _hiddenShownInGroup = group.id;
    }
    final showsHidden = _hiddenShownInGroup != null;
    final hidden = _data.hiddenStationSlugs.value.toSet();
    _content = DesktopBrowseContent.compute(
      listed: showsHidden ? withHidden : listed,
      favoriteSlugs: _favoriteSlugs,
      categoryChosen: group != null,
      shownHidden: showsHidden
          ? {
              for (final station in withHidden)
                if (hidden.contains(station.slug)) station.slug as String,
            }
          : const {},
    );
    if (_searching) _updateSearch();
  }

  /// [offer], with the chosen [group] among its categories even once all
  /// its stations are hidden, so its chip stays the way back.
  static StationGroupCategories _withChosen(
    StationGroupCategories offer,
    Query$GetStations$station_groups? group,
  ) {
    if (group == null || offer.offers(group.id)) return offer;
    // In its place by order, after the others of the same order.
    final at = offer.categories.indexWhere((c) => c.group.order > group.order);
    final categories = [...offer.categories]..insert(
        at < 0 ? offer.categories.length : at,
        StationGroupCategory(group: group, stationCount: 0),
      );
    return StationGroupCategories(
      categories: categories,
      stationCount: offer.stationCount,
      listenerCount: offer.listenerCount,
    );
  }

  /// The search results for [_query] among every visible station, in the
  /// phone's order; a station whose song stops matching plays its row out.
  void _updateSearch() {
    final listed = _data.getSortedStations(applyGroupFilter: false);
    final update = _liveResults.update(
      _query,
      desktopSearchResults(listed, _query),
      {for (final station in listed) station.slug as String},
    );
    _results = update.shown;
    _leaving = _liveResults.leaving;
    if (update.arriving.isNotEmpty) {
      _arriving.addAll(update.arriving);
      // Only the rows built now grow in; one scrolled to later just shows.
      WidgetsBinding.instance.addPostFrameCallback((_) => _arriving.clear());
    }
    _keepHighlightValid();
    _resultKeys.removeWhere(
      (slug, _) => !_results.any((station) => station.slug == slug),
    );
  }

  void _keepHighlightValid() {
    final current = _highlightSlug;
    final valid = current != null &&
        !_leaving.contains(current) &&
        _results.any((station) => station.slug == current);
    if (!valid) {
      _highlightSlug =
          movedHighlight(_results, null, down: true, skipped: _leaving);
    }
  }

  /// Tells the menu bar and the Dock menu what plays.
  void _syncMenuBar() {
    final station = _currentStation;
    final recent = [
      for (final offered in DesktopRecentStations.offered(
        _recent.slugs,
        listed: _data.visibleStations,
        currentSlug: station?.slug,
      ))
        (slug: offered.slug as String, title: offered.displayTitle),
    ];
    final state = (
      hasStation: station != null,
      playing: _playing,
      isFavorite: station != null && _favoriteSlugs.contains(station.slug),
      muted: _audioHandler.listenerVolume.value == 0,
      recent: [for (final r in recent) '${r.slug}:${r.title}'].join('|'),
    );
    if (state == _menuBarState) return;
    _menuBarState = state;
    unawaited(DesktopMenuService.updateState(
      hasStation: state.hasStation,
      playing: state.playing,
      isFavorite: state.isFavorite,
      muted: state.muted,
      recent: recent,
    ));
  }

  /// Asks the Mac App Store for a newer version and offers it; asks again
  /// [_updateCheckInterval] later.
  Future<void> _checkForUpdate() async {
    final release = await _updates.check();
    if (!mounted) return;
    _updateCheck = Timer(_updateCheckInterval, _checkForUpdate);
    if (release == null || _offeringUpdate) return;
    _pendingUpdate = release;
    await _offerPendingUpdate();
  }

  /// Offers [_pendingUpdate], unless a panel or a dialog the listener is
  /// busy with covers the shell: then once it closes (see
  /// [didChangeDependencies]), with the release already found.
  Future<void> _offerPendingUpdate() async {
    final release = _pendingUpdate;
    if (release == null || !mounted || _route?.isCurrent != true) return;
    _pendingUpdate = null;
    _offeringUpdate = true;
    try {
      AnalyticsService.instance
          .capture('update_prompt_shown', {'version': release.version});
      final update = await showDesktopUpdateDialog(
        context,
        release: release,
        currentVersion: globals.appVersion,
      );
      AnalyticsService.instance.capture(
        update ? 'update_prompt_accepted' : 'update_prompt_postponed',
        {'version': release.version},
      );
      if (update) {
        await openMacAppStorePage();
      } else {
        await _updates.postpone(release);
      }
    } finally {
      _offeringUpdate = false;
    }
  }

  /// Deletes the song art cached on disk more than a week ago, keeping the
  /// stations' logos; skipped while the station list, which tells the two
  /// apart, isn't in yet.
  void _pruneImageDiskCache() {
    _imageCachePrune = Timer(_imageCachePruneInterval, _pruneImageDiskCache);
    final stations = _data.stations.value;
    if (stations.isEmpty) return;
    unawaited(Utils.pruneImageDiskCache(
      keepUrls: Utils.stationLogoUrls(stations.map((s) => s.rawStationData)),
    ));
  }

  // ─── Lifecycle ───

  /// Makes the user-chosen order again from the current numbers when the
  /// window comes back into sight after being left for at least
  /// [_chosenOrderKeptFor]: the order is kept meanwhile so that cards
  /// never move under the pointer, but the Mac app stays open for days and
  /// the ranking by listeners would go stale.
  ///
  /// Only as the window shows again, before it is clicked: a window left
  /// in sight and clicked back into keeps its order, as the click lands on
  /// a card. With numbers from before it went away, the order waits for
  /// the fresh ones (see [_remakeChosenOrderIfDue]).
  ///
  /// As the window goes out of sight, the decoded art no card holds is let
  /// go.
  void _onLifecycleChanged(AppLifecycleState state) {
    final now = widget.now();
    final action = _lifecycleTracker.onTransition(state);
    // Out of sight, maybe for hours as the radio plays: the decoded art no
    // card holds goes; what the cards show stays, and is there again.
    if (action == TvLifecycleAction.enteredBackground) {
      PaintingBinding.instance.imageCache.clear();
    }
    final returned = action == TvLifecycleAction.returnedToForeground;
    final leftAt = _leftAt;
    if (returned) {
      _untouchedSinceReturn = true;
      if (leftAt != null && now.difference(leftAt) >= _chosenOrderKeptFor) {
        _remakeDue = true;
      }
      final changedAt = _stationsChangedAt;
      if (changedAt != null && now.difference(changedAt) < _freshNumbers) {
        _remakeChosenOrderIfDue();
      }
    }
    _leftAt = switch (state) {
      AppLifecycleState.resumed => null,
      // Back in sight but not yet clicked: left again from now on.
      _ when returned => now,
      _ => leftAt ?? now,
    };
  }

  /// Makes the user-chosen order again from the stations' numbers now, if
  /// it is due and nothing was pressed since the window came back. Not
  /// while a station's menu is open, as its card would move away from it:
  /// then, like after a press, at the window's next return. "Pentru tine"
  /// stays as made once per session.
  void _remakeChosenOrderIfDue() {
    if (!_remakeDue || !_untouchedSinceReturn || _menuSlug != null) return;
    _remakeDue = false;
    if (_sortOption == StationSortOption.recommended) return;
    _data.invalidateSortCache();
    _refresh();
  }

  /// Plays the station chosen under "Ascultate recent" in the Dock menu.
  void _playRequested(String slug) {
    if (!mounted) return;
    final station =
        _data.visibleStations.where((s) => s.slug == slug).firstOrNull;
    if (station != null) _actions.play(station, source: 'dock_recent');
  }

  // ─── Commands (menu bar, Dock menu, keyboard) ───

  void _onCommand(DesktopCommand command) {
    if (!mounted) return;
    switch (command) {
      case DesktopCommand.playPause:
        _togglePlayback();
      case DesktopCommand.next:
        _skip(forward: true);
      case DesktopCommand.previous:
        _skip(forward: false);
      case DesktopCommand.toggleFavorite:
        final station = _currentStation;
        if (station != null) {
          _actions.toggleFavorite(station, source: 'desktop_command');
        }
      case DesktopCommand.search:
        _focusSearch();
      case DesktopCommand.settings:
        _openSettings();
      case DesktopCommand.nowPlaying:
        _openNowPlaying();
      case DesktopCommand.back:
        _goBack();
      case DesktopCommand.forward:
        _goForward();
      case DesktopCommand.volumeUp:
        _stepVolume(up: true);
      case DesktopCommand.volumeDown:
        _stepVolume(up: false);
      case DesktopCommand.toggleMute:
        unawaited(_audioHandler.toggleListenerMute());
    }
  }

  /// The volume a keyboard step up or down: two wheel notches.
  void _stepVolume({required bool up}) {
    const step = DesktopVolumeControl.step * 2;
    final volume = _audioHandler.listenerVolume.value;
    unawaited(_audioHandler.setListenerVolume(volume + (up ? step : -step)));
  }

  // ─── Back and forward ───

  /// Every press in the window, which is then in use. It takes the keyboard
  /// off the control the arrows left it on; the mouse's back and forward
  /// side buttons go through the stations played.
  void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    // In use: the order stays as it is under the pointer.
    _untouchedSinceReturn = false;
    _revealSkippedTo = false;
    _dropKeyboardFocus();
    if (event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons & kBackMouseButton != 0) {
      _onSideButton(back: true);
    } else if (event.buttons & kForwardMouseButton != 0) {
      _onSideButton(back: false);
    }
  }

  /// Takes the keyboard off the card or the button the arrows or Tab left
  /// it on, as a browser does on a click, so its ring doesn't stay behind
  /// as the pointer is used; the arrows then go through the stations again
  /// (see [_onKey]). A text field lets go by itself when clicked out of,
  /// and an open menu keeps it.
  void _dropKeyboardFocus() {
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null || focused == _scope || !_scope.hasFocus) return;
    final menuOpen = (_menu.currentState?.isOpen ?? false) || _sortMenu.isOpen;
    if (menuOpen || DesktopShortcuts.isEditingText) return;
    focused.unfocus();
  }

  /// The mouse's back and forward side buttons. Over the screen and "Se
  /// redă acum" they go through the stations played, as a browser's go
  /// through the pages visited: back plays the station played before,
  /// forward the one back left. Over Settings or a dialog they step back
  /// and forward there, as ⌘[ and ⌘] do.
  void _onSideButton({required bool back}) {
    final playerInFront = (_route?.isCurrent ?? false) ||
        (_nowPlayingRoute?.isCurrent ?? false);
    if (!playerInFront) {
      DesktopMenuService.dispatch(
          back ? DesktopCommand.back : DesktopCommand.forward);
      return;
    }
    final listed = {
      for (final station in _data.visibleStations)
        station.slug as String: station,
    };
    final slug = back
        ? _played.back(playable: listed.containsKey)
        : _played.forward(playable: listed.containsKey);
    final station = listed[slug];
    if (station == null) return;
    _playButton.currentState?.notifyWillPlay();
    // Next and previous keep stepping through what they did.
    _actions.play(
      station,
      fromFavorites: null,
      source: back ? 'desktop_mouse_back' : 'desktop_mouse_forward',
    );
  }

  /// Steps back one level, as Esc and a browser's back do: closes an open
  /// menu, goes back in Settings, closes "Se redă acum" or a dialog over
  /// it, ends the search, or leaves the chosen category.
  void _goBack() {
    if (_closeMenus()) return;
    switch (DesktopSettingsPanel.goBack()) {
      case true:
        _forwardSteps.add(const _BackStep.settings());
        return;
      case false:
        return;
      case null:
        break;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      final closesNowPlaying = _nowPlayingRoute?.isCurrent ?? false;
      navigator.pop();
      if (closesNowPlaying) _forwardSteps.add(const _BackStep.nowPlaying());
      return;
    }
    if (_searching) {
      final query = _searchText.text;
      _stepThroughHistory(_endSearch);
      _forwardSteps.add(_BackStep.search(query));
      return;
    }
    final group = _selectedGroup;
    if (group != null) {
      _stepThroughHistory(() => _onCategorySelected(null));
      _forwardSteps.add(_BackStep.category(group));
    }
  }

  /// Brings back what the last [_goBack] closed.
  void _goForward() {
    if (_forwardSteps.isEmpty) return;
    final step = _forwardSteps.removeLast();
    _stepThroughHistory(() {
      switch (step) {
        case _ReopenSettings():
          _openSettings();
        case _ReopenNowPlaying():
          _openNowPlaying();
        case _ResumeSearch(:final query):
          _searchText.text = query;
          _onQueryChanged(query);
        case _ReselectCategory(:final group):
          _onCategorySelected(group);
      }
    });
  }

  void _stepThroughHistory(VoidCallback move) {
    _steppingThroughHistory = true;
    try {
      move();
    } finally {
      _steppingThroughHistory = false;
    }
  }

  /// Forgets what forward would bring back, as the listener went somewhere
  /// new.
  void _forgetForward() {
    if (!_steppingThroughHistory) _forwardSteps.clear();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_closeMenus()) return KeyEventResult.handled;
      if (_searching) {
        _endSearch();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // With no card or button on the keyboard (Tab puts it on them), the
    // arrows move the playing station through its grid: ← and → play the
    // one before and after it, as in "Se redă acum", ↑ and ↓ the one above
    // and below.
    if (_isPlainArrow(event) && FocusManager.instance.primaryFocus == _scope) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        _revealSkippedTo = true;
        DesktopMenuService.dispatch(key == LogicalKeyboardKey.arrowRight
            ? DesktopCommand.next
            : DesktopCommand.previous);
      } else {
        _playRowAway(down: key == LogicalKeyboardKey.arrowDown);
      }
      return KeyEventResult.handled;
    }
    final command = DesktopShortcuts.commandFor(
      event,
      editingText: DesktopShortcuts.isEditingText,
      focusActivates: DesktopShortcuts.focusActivates(ignoring: _scope),
    );
    if (command == null) return KeyEventResult.ignored;
    DesktopMenuService.dispatch(command);
    return KeyEventResult.handled;
  }

  static final Set<LogicalKeyboardKey> _arrows = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  /// Whether [event] presses an arrow alone; with ⌘ it skips or sets the
  /// volume.
  static bool _isPlainArrow(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return event is KeyDownEvent &&
        _arrows.contains(event.logicalKey) &&
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
  }

  /// Plays the station one row above or below the playing one in its
  /// grid: in Favorite while next and previous step through the
  /// favorites, else in the grid below. Going down into the last row's
  /// gap plays its last station, as a grid moves; past the first or the
  /// last row nothing changes.
  void _playRowAway({required bool down}) {
    final String? slug = _currentStation?.slug;
    if (slug == null || _searching) return;
    var inFavorites = _data.startedFromFavorites;
    var stations = inFavorites ? _content.favorites : _content.stations;
    if (!stations.any((station) => station.slug == slug)) {
      inFavorites = !inFavorites;
      stations = inFavorites ? _content.favorites : _content.stations;
    }
    final index = stations.indexWhere((station) => station.slug == slug);
    // Both grids have as many columns.
    final columns = (_builtCard(inFavorites: inFavorites) ??
            _builtCard(inFavorites: !inFavorites))
        ?.layout
        .crossAxisCount;
    if (index < 0 || columns == null) return;
    var target = index + (down ? columns : -columns);
    if (target < 0) return;
    if (target >= stations.length) {
      final lastRow = (stations.length - 1) ~/ columns;
      if (index ~/ columns == lastRow) return;
      target = stations.length - 1;
    }
    final station = stations[target];
    if (_content.shownHidden.contains(station.slug)) return;
    _revealSkippedTo = true;
    _playButton.currentState?.notifyWillPlay();
    _actions.play(
      station,
      fromFavorites: null,
      source: down ? 'desktop_arrow_down' : 'desktop_arrow_up',
    );
  }

  /// Scrolls the list just enough to show [slug]'s card whole, below the
  /// pinned section title, if it is out of view: the card in Favorite
  /// while next and previous step through the favorites, else the one
  /// below.
  void _revealCard(String slug) {
    if (!mounted || _searching || !_scroll.hasClients) return;
    final list = _listKey.currentContext?.findRenderObject();
    if (list is! RenderBox || !list.hasSize) return;
    final inFavorites = _data.startedFromFavorites;
    final card = _cardRect(slug, inFavorites: inFavorites) ??
        _cardRect(slug, inFavorites: !inFavorites);
    if (card == null) return;
    const margin = 12.0;
    final view = list.localToGlobal(Offset.zero) & list.size;
    final top = view.top + DesktopTokens.sectionHeaderHeight + margin;
    final bottom = view.bottom - margin;
    final double by;
    if (card.top < top || card.height > bottom - top) {
      by = card.top - top;
    } else if (card.bottom > bottom) {
      by = card.bottom - bottom;
    } else {
      return;
    }
    final position = _scroll.position;
    _scroll.animateTo(
      (position.pixels + by)
          .clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: DesktopTokens.contentDuration,
      curve: Curves.easeInOut,
    );
  }

  /// The global bounds of [slug]'s card in Favorite ([inFavorites]) or in
  /// the grid below, where it is laid out or, not built yet far from the
  /// view, where it will be: the grid's rows are evenly spaced from any
  /// card of it that is.
  Rect? _cardRect(String slug, {required bool inFavorites}) {
    final own = _cardBox(slug, inFavorites: inFavorites);
    if (own != null) return _globalRect(own);
    final stations = inFavorites ? _content.favorites : _content.stations;
    final index = stations.indexWhere((station) => station.slug == slug);
    final built = _builtCard(inFavorites: inFavorites);
    if (index < 0 || built == null) return null;
    final columns = built.layout.crossAxisCount;
    final rows = index ~/ columns - built.index ~/ columns;
    final rect = _globalRect(built.box);
    return rect.translate(
        0, rows * (rect.height + built.layout.mainAxisSpacing));
  }

  /// A card laid out in Favorite ([inFavorites]) or in the grid below,
  /// with its place in it and the grid's layout; null while none is.
  ({
    int index,
    RenderBox box,
    SliverGridDelegateWithFixedCrossAxisCount layout,
  })? _builtCard({required bool inFavorites}) {
    final stations = inFavorites ? _content.favorites : _content.stations;
    for (final (index, station) in stations.indexed) {
      final box = _cardBox(station.slug as String, inFavorites: inFavorites);
      if (box == null) continue;
      final layout =
          _cardKeys[(slug: station.slug as String, inFavorites: inFavorites)]
              ?.currentContext
              ?.findAncestorRenderObjectOfType<RenderSliverGrid>()
              ?.gridDelegate;
      if (layout is! SliverGridDelegateWithFixedCrossAxisCount) return null;
      return (index: index, box: box, layout: layout);
    }
    return null;
  }

  /// [slug]'s card in Favorite ([inFavorites]) or in the grid below, if it
  /// is laid out: one scrolled far out of view is let go.
  RenderBox? _cardBox(String slug, {required bool inFavorites}) {
    final box = _cardKeys[(slug: slug, inFavorites: inFavorites)]
        ?.currentContext
        ?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  static Rect _globalRect(RenderBox box) =>
      box.localToGlobal(Offset.zero) & box.size;

  /// Closes the sort and station menus; returns whether one was open.
  bool _closeMenus() {
    final closedStationMenu = _menu.currentState?.close() ?? false;
    final sortOpen = _sortMenu.isOpen;
    if (sortOpen) _sortMenu.close();
    return closedStationMenu || sortOpen;
  }

  /// Closes whatever covers the screen (a dialog, Settings) and its menus,
  /// so a command from the menu bar acts on the screen itself. Returns
  /// whether something covered it.
  bool _bringToFront() {
    _closeMenus();
    final route = _route;
    if (route == null || route.isCurrent) return false;
    Navigator.of(context).popUntil((r) => r == route || r.isFirst);
    return true;
  }

  void _togglePlayback() {
    if (_currentStation == null) return;
    if (_audioHandler.playbackState.value.playing) {
      unawaited(_audioHandler.pause());
    } else {
      _playButton.currentState?.notifyWillPlay();
      unawaited(_audioHandler.play());
    }
  }

  void _skip({required bool forward}) {
    if (_currentStation == null) return;
    _playButton.currentState?.notifyWillPlay();
    unawaited(
        forward ? _audioHandler.skipToNext() : _audioHandler.skipToPrevious());
  }

  void _focusSearch() {
    if (!_bringToFront()) {
      _focusSearchField();
      return;
    }
    // Once the routes above are gone and have handed the focus back; the
    // frame is asked for, as the app may be idle.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _focusSearchField())
      ..ensureVisualUpdate();
  }

  /// Opens the search field and puts the keyboard in it, its text selected
  /// to be typed over.
  void _focusSearchField() {
    if (!mounted) return;
    if (!_searchOpen) {
      setState(() => _searchOpen = true);
      // The field takes the keyboard once it can, in the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusSearchField());
      return;
    }
    _searchFocus.requestFocus();
    _searchText.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchText.text.length,
    );
  }

  void _openSettings() {
    _forgetForward();
    _closeMenus();
    _closeNowPlaying();
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'settings',
      'source': 'desktop',
    });
    // Does nothing more while the Settings panel is up.
    SettingsPage.show(context);
  }

  /// Opens "Se redă acum" over the window, unless it is open already.
  Future<void> _openNowPlaying() async {
    _forgetForward();
    if (_currentStation == null || _nowPlayingRoute != null) return;
    _bringToFront();
    final navigator = Navigator.of(context);
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    // The player bar opens up into the panel.
    final route = DesktopNowPlayingRoute(
      settings: const RouteSettings(name: '/now-playing'),
      builder: (context) => themes.wrap(
        DesktopNowPlayingSheet(youtubeCountdown: widget.youtubeCountdown),
      ),
    );
    _nowPlayingRoute = route;
    try {
      await navigator.push(route);
    } finally {
      _nowPlayingRoute = null;
    }
  }

  /// Takes "Se redă acum" off the screen at once, with the dialogs opened
  /// from it (its song history, for one), which would otherwise stay over
  /// the grid without it.
  void _closeNowPlaying() {
    final route = _nowPlayingRoute;
    if (route == null || !route.isActive) return;
    Navigator.of(context)
      ..popUntil((r) => r == route || r.isFirst)
      ..removeRoute(route);
  }

  // ─── Browse ───

  void _onSortSelected(StationSortOption option) {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'sort_option',
      'sort_option': option.name,
      'source': 'desktop',
    });
    unawaited(StationSortService.saveSortOption(option));
    _data.invalidateSortCache();
    setState(() {
      _sortOption = option;
      _recompute();
    });
  }

  void _onCategorySelected(Query$GetStations$station_groups? group) {
    _forgetForward();
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'filter',
      'filter_group': group?.name ?? 'all',
      if (group != null) 'filter_group_id': group.id,
      'source': 'desktop',
    });
    // The grid follows once the filtered stations arrive.
    _data.selectedStationGroup.add(group);
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: DesktopTokens.contentDuration,
        curve: Curves.easeInOut,
      );
    }
  }

  void _openStationMenu(
    Station station,
    Offset position, {
    bool fromFavorites = false,
    bool fromPlayer = false,
  }) {
    _menu.currentState?.open(
      station,
      position,
      fromFavorites: fromFavorites,
      fromPlayer: fromPlayer,
    );
  }

  void _onMenuOpenChanged(String? slug) {
    // Called from the menu's own callbacks: rebuilt once they are done.
    scheduleMicrotask(() {
      if (mounted && slug != _menuSlug) setState(() => _menuSlug = slug);
    });
  }

  // ─── Search ───

  void _onQueryChanged(String text) {
    if (text.trim().isNotEmpty) _forgetForward();
    final query = text.trim().isEmpty ? '' : text;
    if (query == _query) return;
    final wasSearching = _searching;
    if (!wasSearching && _scroll.hasClients) {
      _offsetBeforeSearch = _scroll.offset;
    }
    setState(() {
      _query = query;
      _highlightSlug = null;
      if (query.isEmpty) {
        _liveResults.clear();
        _results = const [];
        _leaving = const {};
        _arriving.clear();
      } else {
        _updateSearch();
      }
    });
    // A new search starts at the top; the end of one goes back to where
    // the list was.
    final offset = query.isEmpty ? _offsetBeforeSearch : 0.0;
    if (query.isEmpty) _offsetBeforeSearch = null;
    _updateSearchOpen();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || offset == null) return;
      final position = _scroll.position;
      _scroll.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  void _endSearch() {
    _searchText.clear();
    _onQueryChanged('');
    if (_searchFocus.hasFocus) _searchFocus.unfocus();
  }

  /// Shows the search field while it has the keyboard or a search is on;
  /// left with nothing typed, it folds back into its button.
  void _updateSearchOpen() {
    final open = _searchFocus.hasFocus || _searching;
    if (mounted && open != _searchOpen) setState(() => _searchOpen = open);
  }

  void _playFromSearch(Station station) {
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'search_result_tap',
      'station_id': station.id,
      'station_slug': station.slug,
      'matched_by': stationTitleMatch(station.displayTitle, _query) != null
          ? 'name'
          : 'song',
      'source': 'desktop',
    });
    setState(() => _highlightSlug = station.slug);
    _actions.play(station, source: 'desktop_search');
  }

  void _playHighlighted() {
    final slug = _highlightSlug;
    final station = _results
            .where((s) => s.slug == slug && !_leaving.contains(s.slug))
            .firstOrNull ??
        _results.where((s) => !_leaving.contains(s.slug)).firstOrNull;
    if (station != null) _playFromSearch(station);
  }

  void _moveHighlight({required bool down}) {
    if (!_searching) return;
    final before = _results.indexWhere((s) => s.slug == _highlightSlug);
    final next =
        movedHighlight(_results, _highlightSlug, down: down, skipped: _leaving);
    if (next == null) return;
    final after = _results.indexWhere((s) => s.slug == next);
    setState(() => _highlightSlug = next);
    final wrapped = before >= 0 && (down ? after < before : after > before);
    _revealHighlight(down: down, wrapped: wrapped);
  }

  /// Keeps the highlighted row in view after an arrow key moved it; once
  /// it wrapped around, its row may not be built yet, so the list jumps to
  /// that end first.
  void _revealHighlight({required bool down, required bool wrapped}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (!wrapped) {
        _ensureHighlightVisible(atEnd: down);
        return;
      }
      final position = _scroll.position;
      _scroll
          .jumpTo(down ? position.minScrollExtent : position.maxScrollExtent);
      if (!down) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _ensureHighlightVisible(atEnd: true));
      }
    });
  }

  void _ensureHighlightVisible({required bool atEnd}) {
    final slug = _highlightSlug;
    final row = slug == null ? null : _resultKeys[slug]?.currentContext;
    if (!mounted || row == null) return;
    Scrollable.ensureVisible(
      row,
      duration: DesktopTokens.hoverDuration,
      alignmentPolicy: atEnd
          ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
          : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  void _onResultLeft(String slug) {
    if (!_liveResults.left(slug) || !mounted) return;
    setState(() {
      _results = [
        for (final station in _results)
          if (station.slug != slug) station,
      ];
      _leaving = _liveResults.leaving;
      _keepHighlightValid();
    });
  }

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    final station = _currentStation;
    return FocusScope(
      node: _scope,
      autofocus: true,
      child: DesktopStationMenu(
        key: _menu,
        actions: _actions,
        currentSlug: station?.slug,
        playing: _playing,
        onTogglePlayback: _togglePlayback,
        onOpenChanged: _onMenuOpenChanged,
        child: Scaffold(
          backgroundColor: TvColors.background,
          body: Column(
            children: [
              _NavBar(
                searchOpen: _searchOpen,
                onSearch: _focusSearch,
                searchField: DesktopSearchField(
                  controller: _searchText,
                  focusNode: _searchFocus,
                  onChanged: _onQueryChanged,
                  onSubmitted: _playHighlighted,
                  onMoveHighlight: _moveHighlight,
                  onCancel: _endSearch,
                ),
                onSettings: _openSettings,
              ),
              SizedBox(
                height: DesktopTokens.categoryBarHeight,
                child: AnimatedSwitcher(
                  duration: DesktopTokens.contentDuration,
                  child: _searching
                      ? const _SearchScopeBar(key: ValueKey('scope'))
                      : DesktopCategoryBar(
                          key: const ValueKey('categories'),
                          offer: _categories,
                          selectedGroupId:
                              _categories.offers(_selectedGroup?.id)
                                  ? _selectedGroup?.id
                                  : null,
                          onSelected: _onCategorySelected,
                        ),
                ),
              ),
              const Divider(
                height: 1,
                thickness: 1,
                color: DesktopTokens.hairline,
              ),
              Expanded(
                child: CustomScrollView(
                  key: _listKey,
                  controller: _scroll,
                  slivers: [
                    const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    if (_searching)
                      ..._searchSlivers()
                    else
                      ..._browseSlivers(),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: station == null
              ? null
              : DesktopMiniPlayer(
                  station: station,
                  playing: _playing,
                  isFavorite: _favoriteSlugs.contains(station.slug),
                  playbackState: _audioHandler.playbackState,
                  playButtonKey: _playButton,
                  onOpen: _openNowPlaying,
                  onPlay: () => unawaited(_audioHandler.play()),
                  onPause: () => unawaited(_audioHandler.pause()),
                  onPrevious: () => _skip(forward: false),
                  onNext: () => _skip(forward: true),
                  onToggleFavorite: () => _actions.toggleFavorite(
                    station,
                    source: 'desktop_mini_player',
                  ),
                  onMenu: (position) =>
                      _openStationMenu(station, position, fromPlayer: true),
                  volume: _audioHandler.listenerVolume,
                  onVolumeChanged: (volume) =>
                      unawaited(_audioHandler.setListenerVolume(volume)),
                  onToggleMute: () =>
                      unawaited(_audioHandler.toggleListenerMute()),
                ),
        ),
      ),
    );
  }

  List<Widget> _browseSlivers() {
    final group = _listedGroup;
    final content = _content;
    // Also while the catalog is known but not yet sorted and filtered.
    if (!_catalogLoaded ||
        (group == null && content.stations.isEmpty && _visibleCount > 0)) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: DesktopMessage(
            icon: Icons.radio_rounded,
            title: 'Se încarcă stațiile…',
            loading: true,
          ),
        ),
      ];
    }
    if (group == null && _visibleCount == 0) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: DesktopMessage(
            icon: Icons.visibility_off_outlined,
            title: 'Ai ascuns toate stațiile',
            body: 'Le poți readuce din Setări → Stații ascunse.',
            actionLabel: 'Deschide Setările',
            onAction: _openSettings,
          ),
        ),
      ];
    }
    final shownCount = content.stations.length - content.shownHidden.length;
    return [
      // Always in place, empty without favorites, so the first favorite
      // added doesn't shift the grid in view either.
      DesktopScrollAnchor(
        sliver: content.favorites.isEmpty
            ? const SliverToBoxAdapter()
            : SliverStickyHeader(
                header: DesktopSectionHeader(
                  title: 'Favorite',
                  count: content.favorites.length,
                ),
                sliver: DesktopStationGrid(
                  keyPrefix: 'favorite',
                  stations: content.favorites,
                  cardBuilder: (context, station, metrics) =>
                      _card(context, station, metrics, inFavorites: true),
                ),
              ),
      ),
      SliverStickyHeader(
        header: DesktopSectionHeader(
          title: group?.name ?? DesktopCategoryBar.allLabel,
          count: shownCount,
          trailing: DesktopSortMenu(
            value: _sortOption,
            controller: _sortMenu,
            onSelected: _onSortSelected,
          ),
        ),
        sliver: SliverMainAxisGroup(
          slivers: [
            if (group != null && content.showsHidden)
              SliverToBoxAdapter(
                child: DesktopHiddenNote(
                  text: hiddenInCategoryNote(
                        group.name,
                        hidden: content.shownHidden.length,
                        total: content.stations.length,
                      ) ??
                      '',
                ),
              ),
            if (content.stations.isEmpty)
              SliverToBoxAdapter(
                child: DesktopMessage(
                  icon: Icons.radio_rounded,
                  title: 'Nicio stație în această categorie',
                  actionLabel: 'Arată toate stațiile',
                  onAction: () => _onCategorySelected(null),
                ),
              )
            else
              DesktopStationGrid(
                keyPrefix: 'all',
                stations: content.stations,
                cardBuilder: (context, station, metrics) =>
                    _card(context, station, metrics, inFavorites: false),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _searchSlivers() => [
        DesktopSearchResults(
          query: _query,
          results: _results,
          highlightedSlug: _highlightSlug,
          currentSlug: _currentStation?.slug,
          playing: _playing,
          favoriteSlugs: _favoriteSlugs,
          leaving: _leaving,
          arriving: _arriving,
          menuSlug: _menuSlug,
          rowKey: (slug) => _resultKeys.putIfAbsent(slug, GlobalKey.new),
          onPlay: _playFromSearch,
          onHighlight: (slug) {
            if (slug != _highlightSlug) {
              setState(() => _highlightSlug = slug);
            }
          },
          onContextMenu: (station, position) =>
              _openStationMenu(station, position),
          onLeft: _onResultLeft,
        ),
      ];

  Widget _card(
    BuildContext context,
    Station station,
    DesktopGridMetrics metrics, {
    required bool inFavorites,
  }) {
    final String slug = station.slug;
    final pixels = DesktopStationCard.artworkWidth(metrics.tileWidth) *
        MediaQuery.devicePixelRatioOf(context);
    // In steps, so resizing the window doesn't decode the artwork again
    // at every width.
    final cacheWidth = ((pixels / 64).ceil() * 64).clamp(128, 640);
    final hidden = _content.shownHidden.contains(slug);
    return DesktopStationCard(
      key: _cardKeys.putIfAbsent(
        (slug: slug, inFavorites: inFavorites),
        GlobalKey.new,
      ),
      station: station,
      isCurrent: _currentStation?.slug == slug,
      isPlaying: _playing,
      isFavorite: _favoriteSlugs.contains(slug),
      artworkCacheWidth: cacheWidth,
      // The API's artwork is 250 px wide: sharper copies for larger cards.
      artworkSourceWidth: pixels > 250 ? cacheWidth : null,
      menuOpen: _menuSlug == slug,
      hidden: hidden,
      onUnhide: hidden ? () => _actions.unhide(station) : null,
      onPlay: () => _actions.play(
        station,
        fromFavorites: inFavorites,
        source: inFavorites ? 'desktop_favorites' : 'desktop_grid',
      ),
      onTogglePlayback: _togglePlayback,
      onToggleFavorite: () =>
          _actions.toggleFavorite(station, source: 'desktop_card'),
      onContextMenu: (position) => _openStationMenu(
        station,
        position,
        fromFavorites: inFavorites,
      ),
    );
  }
}

/// The top bar, under the window's transparent title bar, beside the
/// window's buttons: search and Settings at its end. Its empty parts move
/// the window, as a title bar does.
class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.searchOpen,
    required this.searchField,
    required this.onSearch,
    required this.onSettings,
  });

  final bool searchOpen;
  final Widget searchField;
  final VoidCallback onSearch;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DesktopTitleBar>(
      valueListenable: DesktopMenuService.titleBar,
      builder: (context, titleBar, _) => SizedBox(
        height: titleBar.height,
        child: DesktopWindowDragArea(
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: DesktopTokens.gutter - 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SearchToggle(
                    open: searchOpen,
                    field: searchField,
                    onOpen: onSearch,
                  ),
                  const SizedBox(width: 4),
                  _BarIconButton(
                    icon: CupertinoIcons.gear_alt,
                    tooltip: 'Setări (${DesktopShortcuts.settingsHint})',
                    onPressed: onSettings,
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

/// The search button, which unfolds into the search field to its left.
///
/// The field stays built while folded, out of sight and out of the
/// keyboard's reach, so the one field keeps its text and takes the keyboard
/// at once when it opens.
class _SearchToggle extends StatelessWidget {
  const _SearchToggle({
    required this.open,
    required this.field,
    required this.onOpen,
  });

  final bool open;
  final Widget field;
  final VoidCallback onOpen;

  static const double fieldWidth = 340;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.centerRight,
      children: [
        ExcludeFocus(
          excluding: !open,
          child: IgnorePointer(
            ignoring: !open,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: open ? 1 : 0),
              duration: DesktopTokens.contentDuration,
              curve: Curves.easeOutCubic,
              child: SizedBox(width: fieldWidth, child: field),
              builder: (context, unfolded, field) => ClipRect(
                child: Align(
                  alignment: Alignment.centerRight,
                  widthFactor: unfolded,
                  child: Opacity(opacity: unfolded, child: field),
                ),
              ),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: open,
          child: AnimatedOpacity(
            opacity: open ? 0 : 1,
            duration: DesktopTokens.hoverDuration,
            child: _BarIconButton(
              icon: CupertinoIcons.search,
              tooltip: 'Caută (${DesktopShortcuts.searchHint})',
              onPressed: onOpen,
            ),
          ),
        ),
      ],
    );
  }
}

/// A light icon button of the top bar, as macOS draws a toolbar's.
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        foregroundColor: TvColors.textSecondary,
        hoverColor: DesktopTokens.controlHoverFill,
        minimumSize: const Size.square(36),
        fixedSize: const Size.square(36),
        padding: EdgeInsets.zero,
      ),
      icon: Icon(icon, size: 20),
    );
  }
}

/// Stands in for the categories while searching: what the search looks
/// in, and how to end it.
class _SearchScopeBar extends StatelessWidget {
  const _SearchScopeBar({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: DesktopTokens.gutter),
      child: Row(
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 18,
            color: TvColors.textTertiary,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'În toate stațiile, după nume sau după melodia de acum',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: TvColors.textSecondary),
            ),
          ),
          SizedBox(width: 12),
          _Keycap(label: 'Esc'),
          SizedBox(width: 6),
          Text(
            'închide căutarea',
            style: TextStyle(fontSize: 12, color: TvColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// A key, drawn as a keycap.
class _Keycap extends StatelessWidget {
  const _Keycap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: DesktopTokens.controlFill,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: DesktopTokens.hairline),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: TvColors.textSecondary,
        ),
      ),
    );
  }
}

/// Something the browser-style back closed, which forward brings back.
sealed class _BackStep {
  const _BackStep();

  const factory _BackStep.settings() = _ReopenSettings;
  const factory _BackStep.nowPlaying() = _ReopenNowPlaying;
  const factory _BackStep.search(String query) = _ResumeSearch;
  const factory _BackStep.category(Query$GetStations$station_groups group) =
      _ReselectCategory;
}

class _ReopenSettings extends _BackStep {
  const _ReopenSettings();
}

class _ReopenNowPlaying extends _BackStep {
  const _ReopenNowPlaying();
}

class _ResumeSearch extends _BackStep {
  const _ResumeSearch(this.query);

  final String query;
}

class _ReselectCategory extends _BackStep {
  const _ReselectCategory(this.group);

  final Query$GetStations$station_groups group;
}
