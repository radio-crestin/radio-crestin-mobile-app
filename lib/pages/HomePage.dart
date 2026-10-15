import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/FullAudioPlayer.dart';
import 'package:radio_crestin/widgets/share_promotion_card.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

import '../components/MiniAudioPlayer.dart';
import '../components/SelectDialog.dart';
import '../components/StationsList.dart';
import '../main.dart';
import '../queries/getStations.graphql.dart';
import '../services/launch_source_service.dart';
import '../services/network_service.dart';
import '../services/playlist_controller.dart';
import '../services/station_data_service.dart';
import '../services/station_retry.dart';
import '../services/station_sort_service.dart';
import '../widgets/cast_button.dart';
import '../widgets/mini_player_bottom_inset.dart';
import '../widgets/promo_notification_card.dart';
import '../services/home_promo_slot.dart';
import '../services/analytics_service.dart';
import '../services/background_polling_policy.dart';
import '../types/Station.dart';
import '../utils.dart';
import '../utils/PositionRetainedScrollPhysics.dart';
import '../widgets/song_history_modal.dart';
import '../widgets/station_group_chip.dart';
import '../widgets/station_group_filter_sheet.dart';
import '../widgets/status_snackbar.dart';
import '../widgets/status_snackbar_controller.dart';
import 'SettingsPage.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class CustomPanelController extends PanelController {
  final BehaviorSubject<bool> isDraggableSubject = BehaviorSubject.seeded(true);

  /// Whether the panel is expanded enough to show video / YouTube surfaces.
  /// Driven by the panel slide/open/close callbacks; the full player uses it to
  /// hide the inline YouTube iframe while collapsed (the webview stays mounted
  /// and playing — only its inline surface is hidden).
  final BehaviorSubject<bool> isExpandedSubject = BehaviorSubject.seeded(false);

  /// Threshold (0..1) above which the panel counts as expanded. Just below 1 so
  /// the video only appears at the very end of opening and hides the instant a
  /// close starts — no surface bleeds over the mini player during the slide.
  static const double expandedThreshold = 0.92;

  /// Updates [isExpandedSubject] from a panel position, deduping so a slide
  /// doesn't spam identical values every frame.
  void updateExpandedFromPosition(double position) {
    final expanded = position >= expandedThreshold;
    if (isExpandedSubject.value != expanded) {
      isExpandedSubject.add(expanded);
    }
  }

  setIsDraggable(bool isDraggable) {
    assert(isAttached, "PanelController must be attached to a SlidingUpPanel");
    isDraggableSubject.add(isDraggable);
  }
}

class HomePageState {
  final Station? currentStation;
  final List<Station> stations;
  final List<Station> filteredStations;
  final List<Query$GetStations$station_groups> stationGroups;
  final Query$GetStations$station_groups? selectedStationGroup;
  final bool isDraggable;
  final List<String> favoriteSlugs;

  const HomePageState(
    this.currentStation,
    this.stations,
    this.filteredStations,
    this.stationGroups,
    this.selectedStationGroup,
    this.isDraggable,
    this.favoriteSlugs,
  );
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late StreamSubscription _sub;
  CustomPanelController slidingUpPanelController = CustomPanelController();

  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();
  final StationDataService _stationDataService = getIt<StationDataService>();
  final NetworkService _networkService = getIt<NetworkService>();
  final PlaylistController _playlistController = getIt<PlaylistController>();
  final AppLinks _appLinks = AppLinks();

  var autoPlayProcessed = false;

  /// The last deep link handled and when, to drop its duplicate delivery.
  ///
  /// app_links hands a cold-start link both to `getInitialLink()` and to the
  /// first `uriLinkStream` listener. Both sources stay subscribed because an
  /// engine started before the Activity attached can miss either one.
  String? _lastLink;
  DateTime? _lastLinkAt;
  static const _duplicateLinkWindow = Duration(seconds: 3);

  /// Whether the app went to the background (hidden/paused) since the last
  /// `resumed`, as opposed to a brief inactive moment (Control Center,
  /// notification shade, system dialog) where it stayed in the foreground.
  ///
  /// Starts true unless already resumed, so the first resume after a cold
  /// or pre-warmed (Android Auto) start still refreshes as before.
  bool _wasBackgrounded =
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  Timer? _imageCachePruneTimer;
  final GlobalKey<SharePromotionCardState> _sharePromotionKey = GlobalKey();
  ShareLinkData? _shareLinkData;
  /// What the status snackbar says: offline, back online, a station error.
  final StatusSnackbarController _statusSnackbar = StatusSnackbarController();

  /// Room at the end of the station list for the docked offline snackbar.
  final ValueNotifier<double> _statusListInset = ValueNotifier(0.0);

  /// `NetworkService.isOffline`: no network, or no internet through it.
  bool _isOffline = false;
  StreamSubscription? _offlineSub;
  StreamSubscription? _networkSub;
  StreamSubscription? _connectionErrorSub;
  StreamSubscription? _playbackStateSub;
  StreamSubscription? _stationChangeSub;
  StreamSubscription? _videoModeSub;
  StreamSubscription? _videoContentSub;

  /// Identity of the video item for which the user explicitly collapsed the
  /// full player. While it matches the currently-starting video, auto-open is
  /// suppressed (they chose the mini player for THIS item). Cleared implicitly
  /// when a different video starts (a new key no longer matches).
  String? _suppressVideoAutoOpenKey;
  StreamSubscription? _customEventSub;
  final ValueNotifier<double> _panelSlide = ValueNotifier(0.0);
  StationSortOption _sortOption = StationSortOption.recommended;

  /// The promo card above the station list: one at a time.
  HomePromo? _homePromo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sortOption = StationSortService.loadSavedSort();

    // AppLinks initialization (moved from constructor to avoid async work in constructor)
    _appLinks.getInitialLink().then((uri) {
      processIntentUri(uri);
    });
    _sub = _appLinks.uriLinkStream.listen((Uri? uri) {
      processIntentUri(uri);
    }, onError: (err) {
      developer.log("initialLink err:" + err.toString());
    });

    _listenToStatusSnackbarSources();

    // Listen for custom events from notification/Android Auto actions
    _customEventSub = _audioHandler.customEvent.listen((event) {
      if (!mounted) return;
      if (event is Map && event['action'] == 'showSongHistory') {
        final stationId = event['stationId'] as int?;
        final slug = event['stationSlug'] as String?;
        final title = event['stationTitle'] as String?;
        final thumbUrl = event['stationThumbnailUrl'] as String?;
        if (stationId != null && slug != null && title != null) {
          // Open full player panel, then show song history modal
          if (slidingUpPanelController.isAttached) {
            slidingUpPanelController.open();
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            SongHistoryModal.show(
              context,
              stationSlug: slug,
              stationTitle: title,
              stationThumbnailUrl: thumbUrl,
              playedCutoff: () =>
                  _stationDataService.playedCutoffFor(stationId),
            );
          });
        }
      }
    });

    // Auto-open the full player whenever video content starts playing (TV video
    // mode, or a playlist advancing/resuming into a video item) so the picture
    // is immediately visible. Tap-to-open is handled in StationsList; these
    // cover auto-advance and background→foreground resume. `.distinct()` +
    // reacting only to the true transition avoids re-opening on every emit.
    _videoModeSub = _audioHandler.isVideoMode
        .distinct()
        .listen((on) => _maybeAutoOpenForVideo(on));
    _videoContentSub = _playlistController.isVideoContent
        .distinct()
        .listen((on) => _maybeAutoOpenForVideo(on));

    // Defer non-critical work to after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadHomePromo();
      _loadShareLinkData();
      // Well after startup, when station data has loaded and the first
      // images are on screen.
      _imageCachePruneTimer =
          Timer(const Duration(seconds: 30), _pruneImageDiskCache);
    });
  }

  /// Feeds the status snackbar: the network, connection errors, playback
  /// and the current station.
  void _listenToStatusSnackbarSources() {
    _isOffline = _networkService.isOffline.value;
    _offlineSub = _networkService.isOffline.stream
        .listen((offline) => _isOffline = offline);
    _statusSnackbar.playIntent = _audioHandler.hasPlayIntent;
    _updateStatusSnackbarNetwork();
    // `status` tells no network from a network without internet, and
    // `isOnMobileData` which network that is: both shape the offline copy.
    _networkSub = Rx.merge([
      _networkService.status,
      _networkService.isOnMobileData,
    ]).listen((_) {
      if (!mounted) return;
      _statusSnackbar.playIntent = _audioHandler.hasPlayIntent;
      _updateStatusSnackbarNetwork();
    });

    _connectionErrorSub = _audioHandler.connectionError.listen((error) {
      if (!mounted) return;
      // Don't show stale errors when the app is backgrounded (e.g. CarPlay).
      if (WidgetsBinding.instance.lifecycleState !=
          AppLifecycleState.resumed) {
        return;
      }
      // The offline snackbar already says why, and playback resumes on its
      // own once the internet is back: never an error over it.
      if (_isOffline) return;
      final station = _audioHandler.currentStation.valueOrNull;
      final shown = _statusSnackbar.showStationError(
        stationTitle: station?.displayTitle ?? error.stationName,
        reason: error.reason,
        station: station,
      );
      if (shown) HapticFeedback.lightImpact();
    });

    _playbackStateSub = _audioHandler.playbackState.listen((state) {
      _statusSnackbar.updatePlayback(
        playIntent: _audioHandler.hasPlayIntent,
        playingReady: state.playing &&
            state.processingState == AudioProcessingState.ready,
      );
    });
    _stationChangeSub = _audioHandler.currentStation.stream.listen(
        (station) => _statusSnackbar.updateCurrentStation(station?.id));
  }

  void _updateStatusSnackbarNetwork() => _statusSnackbar.updateNetwork(
        _networkService.status.value,
        onMobileData: _networkService.isOnMobileData.value,
      );

  /// Retries the current station now (the station error's "Reîncearcă").
  Future<void> _retryCurrentStation() async {
    final station = _audioHandler.currentStation.valueOrNull;
    if (station == null) return;
    AnalyticsService.instance.capture('button_clicked', {
      'button_name': 'connection_error_retry',
      'station_id': station.id,
      'station_slug': station.slug,
    });
    try {
      await retryStation(
        station,
        handler: _audioHandler,
        playlist: _playlistController,
      );
    } catch (e) {
      developer.log('Error retrying ${station.slug}: $e');
    }
  }

  void _pruneImageDiskCache() {
    final stations = _stationDataService.stations.value;
    // Without the station list, logos cannot be told apart from song art;
    // skip and try again next launch rather than risk deleting them.
    if (stations.isEmpty) return;
    Utils.pruneImageDiskCache(
      keepUrls: Utils.stationLogoUrls(stations.map((s) => s.rawStationData)),
    );
  }

  /// The identity of the currently-playing video content, or null when none.
  /// Playlist video items are keyed by item id; TV channels by station slug.
  String? _currentVideoKey() {
    if (_playlistController.isActive &&
        _playlistController.isVideoContent.value) {
      final id = _playlistController.currentItem.value?.id;
      return id == null ? null : 'pl-$id';
    }
    if (_audioHandler.isVideoModeActive) {
      final slug = _audioHandler.currentStation.valueOrNull?.slug;
      return slug == null ? null : 'tv-$slug';
    }
    return null;
  }

  /// Opens the full player when [videoStarting] is true, unless the user
  /// already collapsed the panel for this exact video item.
  void _maybeAutoOpenForVideo(bool videoStarting) {
    if (!videoStarting || !mounted) return;
    final key = _currentVideoKey();
    if (key == null) return;
    if (key == _suppressVideoAutoOpenKey) return; // user chose the mini player
    final panel = slidingUpPanelController;
    if (panel.isAttached && panel.isPanelClosed) {
      panel.open();
    }
  }

  Future<void> _handleRefresh() async {
    try {
      await Future.wait([
        _stationDataService.refreshStations(),
        _loadHomePromo(),
        _loadShareLinkData(),
      ]).timeout(const Duration(seconds: 3));

      // Refresh share promotion card if it's visible
      if (_homePromo is SharePromo) {
        _sharePromotionKey.currentState?.refreshShareLink();
      }
    } catch (e) {
      developer.log('Error refreshing: $e');
    }
  }

  Future<void> _loadHomePromo() async {
    final promo = await HomePromoSlot(getIt<SharedPreferences>()).current();
    if (mounted) setState(() => _homePromo = promo);
  }

  Future<void> _closeHomePromo() async {
    final promo = _homePromo;
    if (promo == null) return;
    setState(() => _homePromo = null);
    await HomePromoSlot(getIt<SharedPreferences>()).close(promo);
  }

  Future<void> _loadShareLinkData() async {
    try {
      final prefs = getIt<SharedPreferences>();
      String? deviceId = prefs.getString('device_id');
      
      if (deviceId == null) {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          deviceId = androidInfo.id;
        } else if (Platform.isIOS) {
          final iosInfo = await deviceInfo.iosInfo;
          deviceId = iosInfo.identifierForVendor;
        } else {
          deviceId = DateTime.now().millisecondsSinceEpoch.toString();
        }
        
        if (deviceId != null) {
          await prefs.setString('device_id', deviceId);
        }
      }

      final shareService = ShareService(_audioHandler.graphqlClient);
      final data = await shareService.getShareLink(deviceId!);
      
      if (mounted) {
        setState(() {
          _shareLinkData = data;
        });
      }
    } catch (e) {
      developer.log('Error loading share link: $e');
    }
  }

  void _checkPendingSongHistory() {
    final prefs = getIt<SharedPreferences>();
    final slug = prefs.getString('pending_song_history');
    if (slug == null) return;
    prefs.remove('pending_song_history');
    final station = _audioHandler.currentStation.valueOrNull;
    if (station == null || station.slug != slug) return;
    if (slidingUpPanelController.isAttached) {
      slidingUpPanelController.open();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SongHistoryModal.show(
        context,
        stationSlug: station.slug,
        stationTitle: station.title,
        stationThumbnailUrl: station.thumbnailUrl,
        playedCutoff: () => _stationDataService.playedCutoffFor(station.id),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub.cancel();
    _offlineSub?.cancel();
    _networkSub?.cancel();
    _connectionErrorSub?.cancel();
    _playbackStateSub?.cancel();
    _stationChangeSub?.cancel();
    _videoModeSub?.cancel();
    _videoContentSub?.cancel();
    _customEventSub?.cancel();
    _imageCachePruneTimer?.cancel();
    _statusSnackbar.dispose();
    _statusListInset.dispose();
    _panelSlide.dispose();
    super.dispose();
  }

  Widget _buildRoundedIconButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool isActive = false,
  }) {
    return _AnimatedRoundedIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      isActive: isActive,
    );
  }

  void _showSortOptions(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ...StationSortOption.values.map((option) {
                  final isSelected = option == _sortOption;
                  return ListTile(
                    leading: Icon(
                      StationSortLabels.icons[option],
                      size: 20,
                      color: option == StationSortOption.recommended
                          ? const Color(0xFFF59E0B)
                          : isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      StationSortLabels.labels[option] ?? '',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(Icons.check_rounded, size: 20, color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      AnalyticsService.instance.capture('button_clicked', {'button_name': 'sort_option', 'sort_option': option.name});
                      setState(() {
                        _sortOption = option;
                      });
                      StationSortService.saveSortOption(option);
                      _stationDataService.invalidateSortCache();
                      Navigator.pop(context);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFilterOptions(
    BuildContext context,
    List<Station> stations,
    List<Query$GetStations$station_groups> stationGroups,
    Query$GetStations$station_groups? selectedGroup,
  ) {
    StationGroupFilterSheet.show(
      context,
      groups: stationGroups,
      stations: stations,
      selected: selectedGroup,
      onSelected: (group) {
        AnalyticsService.instance.capture('button_clicked', {
          'button_name': 'filter',
          'filter_group': group?.name ?? 'all',
          if (group != null) 'filter_group_id': group.id,
        });
        setState(() {
          _stationDataService.selectedStationGroup.add(group);
        });
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    // Mirror every transition into the audio diagnostic ring buffer so a
    // hiccup that lines up with a screen-lock / foreground-resume is visible
    // to the user when they share the diagnostic.
    _audioHandler.recordLifecycleTransition(state.name);
    // Drive the video↔audio handoff and playlist-sync suspend/resume.
    _audioHandler.onAppLifecycleChanged(state);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _wasBackgrounded = true;
    }
    if (state == AppLifecycleState.resumed) {
      // App returned to foreground — check if audio stream was lost in background
      _audioHandler.reconnectIfNeeded(trigger: ReconnectTrigger.lifecycleResumed);
      // Check for pending song history action (from notification button tap)
      _checkPendingSongHistory();
      if (_wasBackgrounded) {
        _wasBackgrounded = false;
        // Full refresh + resume polling (picks up all changes while backgrounded)
        _stationDataService.onAppResumed();
        // iOS-only: warm resume mirrors cold start. The platform exposes no
        // way to tell "user tapped icon" from "user tapped app-switcher card",
        // so we treat every foreground as "user wants playback" when the
        // setting is on. Android does not need this because the launcher-icon
        // signal is available at process start (FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY).
        if (Platform.isIOS) {
          _resumeAutoplayIfNeeded();
        }
      } else {
        // Only an inactive blip (Control Center, notification shade, system
        // dialog): the app never left the screen, so no full refresh, and
        // no autoplay that would undo a pause made from Control Center.
        // Restart the periodic timer only, in case an idle pause stopped it.
        _stationDataService.resumePolling();
      }
    } else if (state == AppLifecycleState.paused) {
      // App went to background — keep polling if car or cast is connected
      // (user sees metadata on car/cast screen). During casting, player.playing
      // is false (playback is on Cast device), so we must check isCasting too.
      final pause = BackgroundPollingPolicy.shouldPause(
        carConnected: _audioHandler.isCarConnected,
        casting: _audioHandler.isCasting,
        onMobileData: _networkService.isOnMobileData.value,
        playing: _audioHandler.player.playing,
      );
      if (pause) _stationDataService.pausePolling();
    } else if (state == AppLifecycleState.detached) {
      // Flush listening session and analytics before the app is terminated
      AnalyticsService.instance.endListening(reason: 'app_killed');
      AnalyticsService.instance.flush();
      // Stop the audio service when app is being terminated,
      // but keep it alive if CarPlay/Android Auto is connected.
      if (!_audioHandler.isCarConnected) {
        try {
          await _audioHandler.stop();
        } catch (e) {
          developer.log('Error stopping audio service on detach: $e');
        }
      }
    }
  }

  /// Created once: a stream built inside `build` would make the
  /// StreamBuilder cancel and resubscribe all seven sources (and rebuild the
  /// whole page again on their replay) on every HomePage rebuild.
  late final Stream<HomePageState> _homeState = Rx.combineLatest7<
      Station?,
      List<Station>,
      List<Station>,
      List<Query$GetStations$station_groups>,
      Query$GetStations$station_groups?,
      bool,
      List<String>,
      HomePageState>(
    _audioHandler.currentStation.stream,
    _stationDataService.stations.stream,
    _stationDataService.filteredStations.stream,
    _stationDataService.stationGroups,
    _stationDataService.selectedStationGroup.stream,
    slidingUpPanelController.isDraggableSubject,
    _stationDataService.favoriteStationSlugs.stream,
    (currentStation, stations, filteredStations, stationGroups,
            selectedStationGroup, isDraggable, favoriteSlugs) =>
        HomePageState(currentStation, stations, filteredStations,
            stationGroups, selectedStationGroup, isDraggable, favoriteSlugs),
  );

  @override
  Widget build(BuildContext context) {
    // Depend on size and padding only: the full MediaQuery would also
    // rebuild the page on every keyboard-animation frame (viewInsets), e.g.
    // while the search dialog opens above it.
    final panelMaxHeight = MediaQuery.sizeOf(context).height * .9;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    // The panel reaches the screen's bottom edge, so the player's backdrop
    // slides up from it unbroken; the mini player and the full player's
    // content keep this far above it.
    final panelBottomInset = Platform.isIOS ? 12.0 : bottomPadding;
    final panelMinHeight = kMiniPlayerCollapsedHeight + panelBottomInset;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: StreamBuilder<HomePageState>(
          stream: _homeState,
          builder: (context, snapshot) {
            final currentStation = snapshot.data?.currentStation;
            final stations = snapshot.data?.stations ?? [];
            final stationGroups = snapshot.data?.stationGroups ?? [];
            final isDraggable = snapshot.data?.isDraggable ?? true;
            final selectedStationGroup = snapshot.data?.selectedStationGroup;
            final favoriteSlugs = snapshot.data?.favoriteSlugs ?? [];

            // Apply sorting to filtered stations (cached — stable during session)
            final filteredStations = _stationDataService.getSortedStations();

            // Favorites are also kept in the full list below, so liking a
            // station doesn't make it vanish from where the user found it,
            // and the list matches the next/previous order. While a category
            // is chosen the Favorite section hides: its favorites are in the
            // category's list already, and the rest would only push it down.
            final favoriteStations = selectedStationGroup != null
                ? const <Station>[]
                : filteredStations
                    .where((station) => favoriteSlugs.contains(station.slug))
                    .toList();
            final hasMiniPlayer = currentStation != null && stations.isNotEmpty;

            return Stack(
              children: [
              SlidingUpPanel(
              maxHeight: panelMaxHeight,
              minHeight: panelMinHeight,
              backdropEnabled: true,
              backdropTapClosesPanel: true,
              boxShadow: const [],
              controller: slidingUpPanelController,
              onPanelSlide: (position) {
                _panelSlide.value = position;
                // Drive the YouTube inline-surface visibility off the live
                // position so it hides the instant a close starts (no bleed
                // over the mini player during the slide).
                slidingUpPanelController.updateExpandedFromPosition(position);
              },
              onPanelOpened: () {
                slidingUpPanelController.isExpandedSubject.add(true);
                // The playlist track list is only visible while the full player
                // is open — start the 5s live reconcile so item add/remove is
                // reflected, but only for playlist stations.
                if (_audioHandler.currentStation.valueOrNull?.isPlaylist ??
                    false) {
                  _playlistController.startLiveSync();
                }
                // The mirror of the rebuild in onPanelClosed: the collapsed
                // mini player, faded out but still the top 96px of the panel,
                // keeps taking touches until a rebuild turns its IgnorePointer
                // on. Without this, taps on the full player's cast button hit
                // the invisible mini player until something else rebuilds the
                // page.
                if (mounted) setState(() {});
              },
              onPanelClosed: () {
                slidingUpPanelController.isExpandedSubject.add(false);
                // If video is playing as the panel collapses, remember this item
                // so we don't auto-reopen the full player for it — the user
                // deliberately chose the mini player. A different video later
                // has a different key and will auto-open again.
                _suppressVideoAutoOpenKey = _currentVideoKey();
                // Panel hidden — stop the playlist live reconcile (playback
                // continues; the list just isn't on screen). Harmless no-op for
                // non-playlist stations.
                _playlistController.stopLiveSync();
                // SlidingUpPanel2 wraps the collapsed widget in IgnorePointer
                // inside an AnimatedBuilder child, which is only rebuilt on
                // parent rebuilds — not during animation frames. If the widget
                // tree was last built while the panel was open, IgnorePointer
                // stays ignoring=true even after close. Force a rebuild here
                // so the mini player becomes tappable again.
                if (mounted) setState(() {});
              },
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16.0),
                topRight: Radius.circular(16.0),
              ),
              isDraggable: (slidingUpPanelController.isAttached &&
                      (slidingUpPanelController.isPanelClosed ||
                          slidingUpPanelController.isPanelOpen)) ||
                  isDraggable,
              body: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    // Fixed app bar
                    Container(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      // Right inset matches the filter row below, so the
                      // icon glyphs line up with the 16px content gutter.
                      padding: const EdgeInsets.only(top: 6, left: 16, right: 4, bottom: 4),
                      child: Row(
                        children: [
                          const Image(
                            image: AssetImage('assets/icons/ic_logo_filled.png'),
                            width: 40,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "Radio Creștin",
                              style: GoogleFonts.nunito(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const CastButton(),
                          _buildRoundedIconButton(
                            context: context,
                            icon: Icons.search_rounded,
                            tooltip: 'Caută o stație radio',
                            onPressed: () {
                              AnalyticsService.instance.capture('button_clicked', {'button_name': 'search'});
                              showDialog(
                                context: context,
                                builder: (BuildContext context) {
                                  return SelectDialog<Station>(
                                    items: stations,
                                    displayFunction: (Station station) => station.displayTitle,
                                    searchFunction: (Station station) => station.displayTitle,
                                    onItemSelected: (Station station) {
                                      AnalyticsService.instance.capture('button_clicked', {'button_name': 'search_result_tap', 'station_id': station.id, 'station_slug': station.slug});
                                      _audioHandler.playStation(station,
                                          fromFavorites: false);
                                    },
                                    itemBuilder: (context, station) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: 48,
                                              height: 48,
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(10),
                                                child: station.thumbnail,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    station.displayTitle,
                                                    style: TextStyle(
                                                      color: Theme.of(context).colorScheme.onSurface,
                                                      fontWeight: FontWeight.w500,
                                                      fontSize: 15,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                  if (station.songTitle != "")
                                                    Padding(
                                                      padding: const EdgeInsets.only(top: 2),
                                                      child: Text(
                                                        station.songArtist != ""
                                                            ? "${station.songTitle} - ${station.songArtist}"
                                                            : station.songTitle,
                                                        style: TextStyle(
                                                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                                          fontSize: 13,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              );
                            },
                          ),
                          _buildRoundedIconButton(
                            context: context,
                            icon: Icons.settings_outlined,
                            tooltip: 'Setări aplicație',
                            onPressed: () {
                              AnalyticsService.instance.capture('button_clicked', {'button_name': 'settings'});
                              SettingsPage.show(context, shareLinkData: _shareLinkData);
                            },
                          ),
                        ],
                      ),
                    ),
                    // Scrollable station lists
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _handleRefresh,
                        color: Theme.of(context).primaryColor,
                        child: RawScrollbar(
                        padding: const EdgeInsets.only(top: 60),
                        thumbColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
                        radius: const Radius.circular(8),
                        thickness: 4,
                        child: CustomScrollView(
                          physics: const PositionRetainedScrollPhysics().applyTo(const AlwaysScrollableScrollPhysics()),
                          cacheExtent: 300.0,
                          slivers: <Widget>[
                          if (_homePromo
                              case NotificationPromo(:final notification))
                            SliverToBoxAdapter(
                              child: PromoNotificationCard(
                                notification: notification,
                                onDismiss: _closeHomePromo,
                              ),
                            ),
                          if (_homePromo is SharePromo)
                            SliverToBoxAdapter(
                              child: SharePromotionCard(
                                key: _sharePromotionKey,
                                client: _audioHandler.graphqlClient,
                                currentStationSlug: currentStation?.slug,
                                currentStationName: currentStation?.title,
                                onClose: _closeHomePromo,
                              ),
                            ),
                          if (favoriteStations.isNotEmpty)
                            SliverStickyHeader(
                              header: Container(
                                height: 60.0,
                                color: Theme.of(context).scaffoldBackgroundColor,
                                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Favorite',
                                  style: TextStyle(
                                      fontSize: 18, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
                                ),
                              ),
                              sliver: SliverPadding(
                                  padding: const EdgeInsets.only(bottom: 20.0),
                                  sliver: StationsList(
                                    stations: favoriteStations,
                                    currentStation: currentStation,
                                    audioHandler: _audioHandler,
                                    panelController: slidingUpPanelController,
                                    favoriteSlugs: favoriteSlugs,
                                    isFavoritesList: true,
                                  )),
                            ),
                          if (filteredStations.isNotEmpty)
                            SliverStickyHeader(
                              header: Container(
                                height: 60.0,
                                color: Theme.of(context).scaffoldBackgroundColor,
                                padding: const EdgeInsets.only(left: 16.0, right: 4.0),
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: GestureDetector(
                                        onTap: () {
                                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'sort_menu'});
                                          _showSortOptions(context);
                                        },
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              StationSortLabels.icons[_sortOption],
                                              size: 18,
                                              color: _sortOption == StationSortOption.recommended
                                                  ? const Color(0xFFF59E0B)
                                                  : Theme.of(context).colorScheme.onSurface,
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                StationSortLabels.labels[_sortOption] ?? '',
                                                style: TextStyle(
                                                  fontSize: 17,
                                                  fontWeight: FontWeight.w600,
                                                  color: Theme.of(context).colorScheme.onSurface,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.keyboard_arrow_down_rounded,
                                              size: 20,
                                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    // The chosen category stands in for the
                                    // filter button, so it stays in view.
                                    AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 200),
                                      child: selectedStationGroup == null
                                          ? KeyedSubtree(
                                              key: const ValueKey('filter'),
                                              child: _buildRoundedIconButton(
                                                context: context,
                                                icon: Icons.filter_alt_outlined,
                                                tooltip: 'Filtrează',
                                                onPressed: () {
                                                  AnalyticsService.instance.capture('button_clicked', {'button_name': 'filter_menu'});
                                                  _showFilterOptions(context, stations, stationGroups, null);
                                                },
                                              ),
                                            )
                                          : Padding(
                                              key: ValueKey(selectedStationGroup.id),
                                              padding: const EdgeInsets.only(right: 8),
                                              child: StationGroupChip(
                                                group: selectedStationGroup,
                                                onPressed: () {
                                                  AnalyticsService.instance.capture('button_clicked', {'button_name': 'filter_menu', 'source': 'chip'});
                                                  _showFilterOptions(context, stations, stationGroups, selectedStationGroup);
                                                },
                                                onCleared: () {
                                                  AnalyticsService.instance.capture('button_clicked', {'button_name': 'filter', 'filter_group': 'all', 'source': 'chip'});
                                                  setState(() {
                                                    _stationDataService.selectedStationGroup.add(null);
                                                  });
                                                },
                                              ),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                              sliver: StationsList(
                                stations: filteredStations,
                                currentStation: currentStation,
                                audioHandler: _audioHandler,
                                panelController: slidingUpPanelController,
                                favoriteSlugs: favoriteSlugs,
                              ),
                            ),
                          // Bottom inset so the last rows clear the collapsed
                          // mini player. Once, at the very end of the scroll
                          // view — not per section. Animates 0 <-> the
                          // collapsed panel's height as the player appears /
                          // disappears: the list, like the panel, runs to the
                          // screen's bottom edge.
                          MiniPlayerBottomInset(
                            visible: currentStation != null,
                            bottomInset: panelBottomInset,
                          ),
                          // Plus room for the docked offline snackbar while
                          // it shows, so the last rows stay reachable.
                          StatusSnackbarListInset(inset: _statusListInset),
                        ],
                        ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              collapsed: currentStation != null && stations.isNotEmpty
                  ? Container(
                      padding: EdgeInsets.only(
                          bottom: 4 + panelBottomInset, left: 8, right: 8),
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: MiniAudioPlayer(
                        currentStation: currentStation,
                        audioHandler: _audioHandler,
                        panelController: slidingUpPanelController,
                      ),
                    )
                  : null,
              panelBuilder: () => Container(
                decoration: const BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16.0),
                    topRight: Radius.circular(16.0),
                  ),
                ),
                child: currentStation != null
                    ? FullAudioPlayer(
                        audioHandler: _audioHandler,
                        slidingUpPanelController: slidingUpPanelController,
                        panelTravel: panelMaxHeight - panelMinHeight,
                        bottomInset: panelBottomInset,
                      )
                    : null,
              ),
            ),
              // Offline, back online and station errors, one at a time,
              // above the mini player and rising with the full player.
              Positioned.fill(
                child: StatusSnackbarOverlay(
                  controller: _statusSnackbar,
                  panelPosition: _panelSlide,
                  panelTravel: panelMaxHeight - panelMinHeight,
                  dockedBottom: statusSnackbarDockedBottom(
                    hasMiniPlayer: hasMiniPlayer,
                    bottomSafeArea: bottomPadding,
                    panelBottomInset: panelBottomInset,
                  ),
                  listInset: _statusListInset,
                  listReservedInset:
                      currentStation != null ? panelMinHeight : 0,
                  onRetry: _retryCurrentStation,
                ),
              ),
            ],
            );
          }),
    );
  }

  Future<void> playByStationSlug(String stationSlug) async {
    developer.log("playByStationSlug:$stationSlug");
    await waitForStationsUpdate();
    // Look up directly from the source-of-truth (StationDataService) to avoid
    // race condition where stationsMediaItems hasn't been updated yet.
    final allStations = _stationDataService.stations.value;
    final station = allStations.cast<Station?>().firstWhere(
      (s) => s!.slug == stationSlug,
      orElse: () => null,
    );
    if (station != null) {
      developer.log("found station:${station.title}");
      // The link decided what plays on this launch; a later fallback must
      // not replace it with the last-played station.
      autoPlayProcessed = true;
      await _audioHandler.playStation(station, fromFavorites: false);
    } else {
      developer.log("station not found:$stationSlug");
      // An unknown or stale link should still open the app the way a plain
      // launch does. No-op if autoplay already ran for this launch.
      playerAutoplay();
    }
  }

  Future<void> waitForStationsUpdate() {
    if (_stationDataService.stations.value.isNotEmpty) return Future.value();
    return _stationDataService.stations.stream
        .firstWhere((stations) => stations.isNotEmpty)
        .timeout(const Duration(seconds: 5), onTimeout: () => <Station>[]);
  }

  Future<void> processIntentUri(Uri? uri) async {
    try {
      developer.log("processIntentUri:$uri");
      if (uri == null) {
        playerAutoplay();
        return;
      }
      if (_isDuplicateLink(uri)) return;

      final stationSlug = Utils.stationSlugFromUri(uri);
      if (stationSlug.isEmpty) {
        // A root link (e.g. sharing the app itself) names no station.
        playerAutoplay();
        return;
      }
      playByStationSlug(stationSlug);
    } catch (e) {
      developer.log("processIntentUri error:$e");
    }
  }

  /// Whether [uri] is the same link handled moments ago (the cold-start
  /// double delivery). A later re-tap of the same link or NFC tag falls
  /// outside the window and is handled again.
  bool _isDuplicateLink(Uri uri) {
    final link = uri.toString();
    final now = DateTime.now();
    final lastAt = _lastLinkAt;
    if (link == _lastLink &&
        lastAt != null &&
        now.difference(lastAt) < _duplicateLinkWindow) {
      return true;
    }
    _lastLink = link;
    _lastLinkAt = now;
    return false;
  }

  Future<void> playerAutoplay() async {
    if(!autoPlayProcessed) {
      autoPlayProcessed = true;
      await waitForStationsUpdate();
      final prefs = getIt<SharedPreferences>();
      final autoStart = prefs.getBool('_autoStartStation') ?? true;
      var station = await _audioHandler.getLastPlayedStation();
      if (station == null) return;

      // Suppress autoplay when the cold start came from the recents list
      // (Android task switcher) — the user is just inspecting the app, not
      // re-launching it. CarPlay/Android Auto override this: a connected car
      // means the user wants playback regardless of how the phone UI started.
      // iOS always reports "launcher" because the platform can't distinguish
      // icon-tap from switcher-tap, so iOS users always get the silent
      // autoplay path.
      final source = await LaunchSourceService.get();
      final carConnected = _audioHandler.isCarConnected;
      final fromRecents =
          source == LaunchSource.recents && !carConnected;

      if (autoStart && !fromRecents) {
        _audioHandler.playStation(station);
      } else {
        _audioHandler.selectStation(station);
      }
    }
  }

  /// iOS-only: re-engage playback when the app comes back to the foreground
  /// after the user paused. Mirrors the cold-start autoplay rule — if the
  /// user has the "Pornește automat ultima stație" setting on, every
  /// foreground is treated like an icon tap. CarPlay handles its own
  /// autoplay-on-connect, and casting owns playback while active, so both
  /// are skipped here. `playStation` short-circuits when the station is
  /// already playing/loading, so a quick app-switch round-trip is a no-op.
  Future<void> _resumeAutoplayIfNeeded() async {
    if (_audioHandler.playbackState.value.playing) return;
    if (_audioHandler.isCasting) return;
    if (_audioHandler.isCarConnected) return;

    final prefs = getIt<SharedPreferences>();
    final autoStart = prefs.getBool('_autoStartStation') ?? true;
    if (!autoStart) return;

    final station = _audioHandler.currentStation.valueOrNull
        ?? await _audioHandler.getLastPlayedStation();
    if (station == null) return;

    _audioHandler.playStation(station);
  }
}

class _AnimatedRoundedIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isActive;

  const _AnimatedRoundedIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isActive = false,
  });

  @override
  State<_AnimatedRoundedIconButton> createState() => _AnimatedRoundedIconButtonState();
}

class _AnimatedRoundedIconButtonState extends State<_AnimatedRoundedIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    _controller.forward();
  }

  void _onTapUp(TapUpDetails _) {
    _controller.reverse();
  }

  void _onTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ScaleTransition(
      scale: _scaleAnimation,
      child: Semantics(
        button: true,
        child: Material(
          // Idle buttons are bare icons; the circle shows only as the press
          // ripple, or as a tint while a state is on (e.g. a filter is set).
          color: widget.isActive
              ? colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            // `onTap` (not `onTapUp`) carries the action: it is what InkWell
            // exposes to TalkBack/VoiceOver, Switch/Voice Access and the
            // keyboard. It fires right after `onTapUp` in the same gesture.
            onTap: widget.onPressed,
            onTapDown: _onTapDown,
            onTapUp: _onTapUp,
            onTapCancel: _onTapCancel,
            customBorder: const CircleBorder(),
            child: Tooltip(
              message: widget.tooltip,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  widget.icon,
                  size: 22,
                  color: widget.isActive
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
