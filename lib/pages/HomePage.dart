import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/FullAudioPlayer.dart';
import 'package:radio_crestin/widgets/share_promotion_card.dart';
import 'package:radio_crestin/widgets/share_handler.dart';
import 'package:radio_crestin/services/share_service.dart';
import 'package:radio_crestin/utils/share_utils.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';

import '../components/MiniAudioPlayer.dart';
import '../components/SelectDialog.dart';
import '../components/StationsList.dart';
import '../globals.dart' as globals;
import '../main.dart';
import '../queries/getStations.graphql.dart';
import '../services/launch_source_service.dart';
import '../services/network_service.dart';
import '../services/station_data_service.dart';
import '../services/station_sort_service.dart';
import '../widgets/connectivity_banner.dart';
import '../widgets/bottom_toast.dart';
import '../widgets/cast_button.dart';
import '../widgets/promo_notification_card.dart';
import '../services/promo_notification_service.dart';
import '../services/analytics_service.dart';
import '../types/Station.dart';
import '../utils/PositionRetainedScrollPhysics.dart';
import '../widgets/song_history_modal.dart';
import 'SettingsPage.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class CustomPanelController extends PanelController {
  final BehaviorSubject<bool> isDraggableSubject = BehaviorSubject.seeded(true);

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
  final AppLinks _appLinks = AppLinks();

  var autoPlayProcessed = false;
  bool _showSharePromotion = false;
  final GlobalKey<SharePromotionCardState> _sharePromotionKey = GlobalKey();
  ShareLinkData? _shareLinkData;
  bool _isLoadingShareData = true;
  bool _isOffline = false;
  bool _showBackOnline = false;
  Timer? _backOnlineTimer;
  StreamSubscription? _offlineSub;
  StreamSubscription? _connectionErrorSub;
  StreamSubscription? _customEventSub;
  OverlayEntry? _activeConnectionToast;
  final ValueNotifier<double> _panelSlide = ValueNotifier(0.0);
  StationSortOption _sortOption = StationSortOption.recommended;
  PromoNotification? _currentPromoNotification;

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

    _isOffline = _networkService.isOffline.value;
    _offlineSub = _networkService.isOffline.stream.listen((offline) {
      if (!mounted) return;
      if (!offline && _isOffline) {
        // Was offline, now back online — show "back online" banner
        _backOnlineTimer?.cancel();
        setState(() {
          _isOffline = false;
          _showBackOnline = true;
        });
        _backOnlineTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _showBackOnline = false);
        });
      } else {
        setState(() => _isOffline = offline);
      }
    });

    _connectionErrorSub = _audioHandler.connectionError.listen((error) {
      if (!mounted) return;
      // Don't show stale error toasts when app is backgrounded (e.g. using CarPlay)
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
      final stationPart = error.stationName.isNotEmpty
          ? '"${error.stationName}"'
          : 'stația radio';
      final String title;
      final String message;
      final IconData icon;
      switch (error.reason) {
        case ConnectionErrorReason.timeout:
          title = 'Eroare conexiune';
          message = 'Conexiunea la $stationPart a expirat.';
          icon = Icons.timer_off_rounded;
          break;
        case ConnectionErrorReason.network:
          title = 'Eroare conexiune';
          message = 'Verifică conexiunea la internet.';
          icon = Icons.wifi_off_rounded;
          break;
        case ConnectionErrorReason.httpError:
          title = 'Stație indisponibilă';
          message = 'Serverul $stationPart a returnat eroarea ${error.details ?? "necunoscută"}.';
          icon = Icons.cloud_off_rounded;
          break;
        case ConnectionErrorReason.unknown:
          title = 'Stație indisponibilă';
          message = 'Nu s-a putut conecta la $stationPart.';
          icon = Icons.error_outline_rounded;
          break;
      }
      removeBottomToast(_activeConnectionToast);
      _activeConnectionToast = showBottomToast(
        context,
        title: title,
        message: message,
        icon: icon,
        isError: true,
        onDismissed: () { _activeConnectionToast = null; },
      );
    });

    // Listen for custom events from notification/Android Auto actions
    _customEventSub = _audioHandler.customEvent.listen((event) {
      if (!mounted) return;
      if (event is Map && event['action'] == 'showSongHistory') {
        final slug = event['stationSlug'] as String?;
        final title = event['stationTitle'] as String?;
        final thumbUrl = event['stationThumbnailUrl'] as String?;
        if (slug != null && title != null) {
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
            );
          });
        }
      }
    });

    // Defer non-critical work to after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSharePromotionVisibility();
      _loadShareLinkData();
      _loadPromoNotification();
    });
  }

  Future<void> _handleRefresh() async {
    try {
      await Future.wait([
        _stationDataService.refreshStations(),
        _checkSharePromotionVisibility(),
        _loadShareLinkData(),
      ]).timeout(const Duration(seconds: 3));

      // Refresh share promotion card if it's visible
      if (_showSharePromotion && _sharePromotionKey.currentState != null) {
        _sharePromotionKey.currentState!.refreshShareLink();
      }
    } catch (e) {
      developer.log('Error refreshing: $e');
    }
  }

  Future<void> _checkSharePromotionVisibility() async {
    final prefs = getIt<SharedPreferences>();
    bool shouldShow = prefs.getBool('show_share_promotion') ?? false;

    // Check if we've already auto-enabled before (to not override user's choice)
    bool hasAutoEnabled = prefs.getBool('share_promotion_auto_enabled') ?? false;

    // Auto-enable after 40 actions (2X the review threshold) - but only once
    if (!shouldShow && !hasAutoEnabled) {
      String? reviewStatusJson = prefs.getString('_reviewStatus');
      if (reviewStatusJson != null) {
        Map<String, dynamic> reviewStatus = json.decode(reviewStatusJson);
        int actionsMade = reviewStatus['actions_made'] ?? 0;

        // Auto-enable at 40 actions (2X the first review threshold of 20)
        if (actionsMade >= 40) {
          await prefs.setBool('show_share_promotion', true);
          await prefs.setBool('share_promotion_auto_enabled', true);
          shouldShow = true;
        }
      }
    }

    if (mounted && shouldShow != _showSharePromotion) {
      setState(() {
        _showSharePromotion = shouldShow;
      });
    }
  }

  void _loadPromoNotification() {
    final prefs = getIt<SharedPreferences>();
    final service = PromoNotificationService(prefs);
    final next = service.getNextNotification();
    if (mounted && next != _currentPromoNotification) {
      setState(() {
        _currentPromoNotification = next;
      });
    }
  }

  Future<void> _dismissPromoNotification() async {
    final notification = _currentPromoNotification;
    if (notification == null) return;
    final prefs = getIt<SharedPreferences>();
    final service = PromoNotificationService(prefs);
    await service.dismiss(notification.id);
    if (mounted) {
      setState(() {
        _currentPromoNotification = null;
      });
    }
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
          _isLoadingShareData = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingShareData = false;
        });
      }
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
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub.cancel();
    _offlineSub?.cancel();
    _connectionErrorSub?.cancel();
    _customEventSub?.cancel();
    _backOnlineTimer?.cancel();
    removeBottomToast(_activeConnectionToast);
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
    List<Query$GetStations$station_groups> stationGroups,
    Query$GetStations$station_groups? selectedGroup,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sortedGroups = List<Query$GetStations$station_groups>.from(stationGroups)
      ..sort((a, b) => a.order.compareTo(b.order));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Filtrează stații',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
                Divider(height: 1, thickness: 0.5, color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06)),
                // Scrollable list
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.only(top: 4, bottom: 24),
                    children: [
                      // "All stations" option
                      ListTile(
                        leading: Icon(
                          Icons.radio_rounded,
                          size: 20,
                          color: selectedGroup == null
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        title: Text(
                          'Toate stațiile radio',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: selectedGroup == null ? FontWeight.w600 : FontWeight.w400,
                            color: selectedGroup == null
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        trailing: selectedGroup == null
                            ? Icon(Icons.check_rounded, size: 20, color: Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: () {
                          AnalyticsService.instance.capture('button_clicked', {'button_name': 'filter', 'filter_group': 'all'});
                          setState(() {
                            _stationDataService.selectedStationGroup.add(null);
                          });
                          Navigator.pop(context);
                        },
                      ),
                      ...sortedGroups.map((group) {
                        final isSelected = selectedGroup?.id == group.id;
                        return ListTile(
                          leading: Icon(
                            Icons.folder_rounded,
                            size: 20,
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            group.name,
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
                            AnalyticsService.instance.capture('button_clicked', {'button_name': 'filter', 'filter_group': group.name, 'filter_group_id': group.id});
                            setState(() {
                              _stationDataService.selectedStationGroup.add(group);
                            });
                            Navigator.pop(context);
                          },
                        );
                      }),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    // Mirror every transition into the audio diagnostic ring buffer so a
    // hiccup that lines up with a screen-lock / foreground-resume is visible
    // to the user when they share the diagnostic.
    _audioHandler.recordLifecycleTransition(state.name);
    if (state == AppLifecycleState.resumed) {
      // App returned to foreground — check if audio stream was lost in background
      _audioHandler.reconnectIfNeeded();
      // Full refresh + resume polling (picks up all changes while backgrounded)
      _stationDataService.onAppResumed();
      // Check for pending song history action (from notification button tap)
      _checkPendingSongHistory();
      // Autoplay is handled exclusively in initState() (cold start).
      // Returning from background should NEVER trigger autoplay.
    } else if (state == AppLifecycleState.paused) {
      // App went to background — keep polling if car or cast is connected
      // (user sees metadata on car/cast screen). During casting, player.playing
      // is false (playback is on Cast device), so we must check isCasting too.
      final carConnected = _audioHandler.isCarConnected;
      final casting = _audioHandler.isCasting;
      if (!carConnected && !casting && (_networkService.isOnMobileData.value || !_audioHandler.player.playing)) {
        _stationDataService.pausePolling();
      }
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

  String _formatVisitCount(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(count % 1000000 == 0 ? 0 : 1)}M';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(count % 1000 == 0 ? 0 : 1)}k';
    }
    return count.toString();
  }

  void _shareApp(BuildContext context) {
    final currentStation = _audioHandler.currentStation.valueOrNull;
    final slug = currentStation?.slug;
    final fallbackUrl = slug != null && slug.isNotEmpty
        ? 'https://www.radiocrestin.ro/$slug'
        : 'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin';

    ShareHandler.shareApp(
      context: context,
      shareUrl: _shareLinkData?.generateShareUrl(stationSlug: slug, songId: currentStation?.songId) ?? fallbackUrl,
      shareMessage: 'Instalează și tu aplicația Radio Creștin și ascultă peste 60 de stații de radio creștin:\n$fallbackUrl',
      stationName: currentStation?.title,
      songName: currentStation?.songTitle,
      songArtist: currentStation?.songArtist,
      songId: currentStation?.songId,
      shareLinkData: _shareLinkData,
      showDialog: true,
      shareLinkLoader: _shareLinkData == null
          ? () async {
              final prefs = getIt<SharedPreferences>();
              final deviceId = prefs.getString('device_id');
              if (deviceId == null) return null;
              final shareService = ShareService(_audioHandler.graphqlClient);
              return shareService.getShareLink(deviceId);
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    double panelMaxHeight = MediaQuery.of(context).size.height * .9;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: StreamBuilder<HomePageState>(
          stream: Rx.combineLatest7<
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
            (currentStation, stations, filteredStations, stationGroups, selectedStationGroup,
                    isDraggable, favoriteSlugs) =>
                HomePageState(currentStation, stations, filteredStations, stationGroups,
                    selectedStationGroup, isDraggable, favoriteSlugs),
          ),
          builder: (context, snapshot) {
            final currentStation = snapshot.data?.currentStation;
            final stations = snapshot.data?.stations ?? [];
            final stationGroups = snapshot.data?.stationGroups ?? [];
            final isDraggable = snapshot.data?.isDraggable ?? true;
            final selectedStationGroup = snapshot.data?.selectedStationGroup;
            final favoriteSlugs = snapshot.data?.favoriteSlugs ?? [];

            // Apply sorting to filtered stations (cached — stable during session)
            final filteredStations = _stationDataService.getSortedStations();

            final favoriteStations = filteredStations.where((station) => favoriteSlugs.contains(station.slug)).toList();
            final nonFavoriteStations = filteredStations.where((station) => !favoriteSlugs.contains(station.slug)).toList();

            return Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: EdgeInsets.only(bottom: Platform.isIOS ? 12 : bottomPadding),
              child: Stack(
              children: [
              SlidingUpPanel(
              maxHeight: panelMaxHeight - (Platform.isIOS ? 12 : bottomPadding),
              minHeight: 96,
              backdropEnabled: true,
              backdropTapClosesPanel: true,
              boxShadow: const [],
              controller: slidingUpPanelController,
              onPanelSlide: (position) {
                _panelSlide.value = position;
              },
              onPanelClosed: () {
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
                      padding: const EdgeInsets.only(top: 6, left: 16, right: 8, bottom: 4),
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
                                      _audioHandler.playStation(station);
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
                                                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
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
                          const SizedBox(width: 8),
                          _buildRoundedIconButton(
                            context: context,
                            icon: Icons.settings_rounded,
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
                          if (_currentPromoNotification != null)
                            SliverToBoxAdapter(
                              child: PromoNotificationCard(
                                notification: _currentPromoNotification!,
                                onDismiss: _dismissPromoNotification,
                              ),
                            ),
                          if (_showSharePromotion)
                            SliverToBoxAdapter(
                              child: SharePromotionCard(
                                key: _sharePromotionKey,
                                client: _audioHandler.graphqlClient,
                                currentStationSlug: currentStation?.slug,
                                currentStationName: currentStation?.title,
                                onClose: () async {
                                  setState(() {
                                    _showSharePromotion = false;
                                  });
                                  final prefs = getIt<SharedPreferences>();
                                  await prefs.setBool('show_share_promotion', false);
                                },
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
                                    panelController: null,
                                    favoriteSlugs: favoriteSlugs,
                                    isFavoritesList: true,
                                  )),
                            ),
                          if (nonFavoriteStations.isNotEmpty)
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
                                    _buildRoundedIconButton(
                                      context: context,
                                      icon: selectedStationGroup != null
                                          ? Icons.filter_alt_rounded
                                          : Icons.filter_alt_outlined,
                                      tooltip: selectedStationGroup?.name ?? 'Filtrează',
                                      isActive: selectedStationGroup != null,
                                      onPressed: () {
                                        AnalyticsService.instance.capture('button_clicked', {'button_name': 'filter_menu'});
                                        _showFilterOptions(context, stationGroups, selectedStationGroup);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              sliver: SliverPadding(
                                  padding: EdgeInsets.only(bottom: Platform.isIOS ? 80.0 : 110.0),
                                  sliver: StationsList(
                                    stations: nonFavoriteStations,
                                    currentStation: currentStation,
                                    audioHandler: _audioHandler,
                                    panelController: null,
                                    favoriteSlugs: favoriteSlugs,
                                  )),
                            ),
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
                      padding: const EdgeInsets.only(bottom: 4, left: 8, right: 8),
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
                      )
                    : null,
              ),
            ),
              if (_isOffline || _showBackOnline)
                Positioned(
                  bottom: Platform.isIOS ? 88 : 82,
                  left: 8,
                  right: 8,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _panelSlide,
                    child: ConnectivityBanner(
                      isOffline: _isOffline,
                      showBackOnline: _showBackOnline,
                    ),
                    builder: (context, position, child) {
                      final slideOffset = position * (panelMaxHeight - 100.0);
                      return Transform.translate(
                        offset: Offset(0, -slideOffset),
                        child: child,
                      );
                    },
                  ),
                ),
            ],
            ),
            );
          }),
    );
  }

  playByStationSlug(String stationSlug) async {
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
      await _audioHandler.playStation(station);
    } else {
      developer.log("station not found:$stationSlug");
    }
  }

  Future<void> waitForStationsUpdate() {
    if (_stationDataService.stations.value.isNotEmpty) return Future.value();
    return _stationDataService.stations.stream
        .firstWhere((stations) => stations.isNotEmpty)
        .timeout(const Duration(seconds: 5), onTimeout: () => <Station>[]);
  }

  String extractSlugWithRegex(String url) {
    final regex = RegExp(r'https?://[^/]+/([^/]+)');
    final match = regex.firstMatch(url);

    if (match != null && match.groupCount >= 1) {
      return match.group(1)!;
    }

    return '';
  }

  processIntentUri(Uri? uri) async {
    try {
      developer.log("processIntentUri:$uri");
      if (uri == null) {
        playerAutoplay();
        return;
      }

      var stationSlug = extractSlugWithRegex(uri.toString());

      if (stationSlug == "") {
        stationSlug = uri.host;
      }
      playByStationSlug(stationSlug);
    } catch (e) {
      developer.log("processIntentUri error:$e");
    }
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
    widget.onPressed();
  }

  void _onTapCancel() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScaleTransition(
      scale: _scaleAnimation,
      child: Material(
        color: widget.isActive
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
            : isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.06),
        shape: const CircleBorder(),
        child: InkWell(
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
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
