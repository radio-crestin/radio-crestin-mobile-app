import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
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
import '../services/network_service.dart';
import '../services/play_count_service.dart';
import '../services/station_data_service.dart';
import '../services/station_sort_service.dart';
import '../widgets/connectivity_banner.dart';
import '../widgets/bottom_toast.dart';
import '../types/Station.dart';
import '../utils/PositionRetainedScrollPhysics.dart';
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
  OverlayEntry? _activeConnectionToast;
  final ValueNotifier<double> _panelSlide = ValueNotifier(0.0);
  StationSortOption _sortOption = StationSortOption.recommended;
  final PlayCountService _playCountService = getIt<PlayCountService>();

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

    // Defer non-critical work to after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSharePromotionVisibility();
      _loadShareLinkData();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub.cancel();
    _offlineSub?.cancel();
    _connectionErrorSub?.cancel();
    _backOnlineTimer?.cancel();
    removeBottomToast(_activeConnectionToast);
    _panelSlide.dispose();
    super.dispose();
  }

  @override
  Widget _buildRoundedIconButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool isActive = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isActive
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
          : isDark
              ? Colors.white.withValues(alpha: 0.07)
              : Colors.black.withValues(alpha: 0.06),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(
              icon,
              size: 20,
              color: isActive
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
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
                      setState(() {
                        _sortOption = option;
                      });
                      StationSortService.saveSortOption(option);
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
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
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
        );
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      // App returned to foreground — check if audio stream was lost in background
      _audioHandler.reconnectIfNeeded();
      // Full refresh + resume polling (picks up all changes while backgrounded)
      _stationDataService.onAppResumed();
      // Auto-play if the "always play" toggle is enabled and not already playing.
      // Use isPlayingOrConnecting to avoid interrupting playback that is still
      // buffering (e.g. during cold start where resumed fires before audio is ready).
      try {
        if (!_audioHandler.isPlayingOrConnecting) {
          autoPlayProcessed = false;
          playerAutoplay();
        }
      } catch (e) {
        developer.log('Error autoplaying on resume: $e');
      }
    } else if (state == AppLifecycleState.paused) {
      // App went to background — on mobile data, always pause polling to save data.
      // On WiFi, only pause if not playing.
      if (_networkService.isOnMobileData.value || !_audioHandler.player.playing) {
        _stationDataService.pausePolling();
      }
    } else if (state == AppLifecycleState.detached) {
      // Stop the audio service when app is being terminated
      try {
        await _audioHandler.stop();
      } catch (e) {
        developer.log('Error stopping audio service on detach: $e');
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

  Future<void> _shareApp(BuildContext context) async {
    try {
      // Get device ID
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

      // Get GraphQL client
      final shareService = ShareService(_audioHandler.graphqlClient);
      final shareLinkData = await shareService.getShareLink(deviceId!);
      
      if (shareLinkData != null) {
        final currentStation = _audioHandler.currentStation.valueOrNull;
        final shareUrl = shareLinkData.generateShareUrl(
          stationSlug: currentStation?.slug,
        );
        final shareMessage = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: currentStation?.title,
          stationSlug: currentStation?.slug,
        );

        // Show dialog with share options
        if (mounted) {
          ShareHandler.shareApp(
            context: context,
            shareUrl: shareUrl,
            shareMessage: shareMessage,
            stationName: currentStation?.title,
            shareLinkData: shareLinkData,
            showDialog: true,
          );
        }
      }
    } catch (e) {
      // Fallback to old method if something fails
      if (mounted) {
        final slug = _audioHandler.currentStation.valueOrNull?.slug;
        final fallbackUrl = slug != null && slug.isNotEmpty
            ? 'https://www.radiocrestin.ro/$slug'
            : 'https://www.radiocrestin.ro/descarca-aplicatia-radio-crestin';
        ShareHandler.shareApp(
          context: context,
          shareUrl: fallbackUrl,
          shareMessage: 'Aplicația Radio Creștin:\n$fallbackUrl',
          showDialog: false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    double panelMaxHeight = MediaQuery.of(context).size.height * .9;

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
            final rawFilteredStations = snapshot.data?.filteredStations ?? [];
            final favoriteSlugs = snapshot.data?.favoriteSlugs ?? [];

            // Apply sorting to filtered stations
            final sortResult = StationSortService.sort(
              stations: rawFilteredStations,
              sortBy: _sortOption,
              playCounts: _playCountService.playCounts,
              favoriteSlugs: favoriteSlugs,
            );
            final filteredStations = sortResult.sorted;

            final favoriteStations = stations.where((station) => favoriteSlugs.contains(station.slug)).toList();

            return Stack(
              children: [
              SlidingUpPanel(
              maxHeight: panelMaxHeight,
              // minHeight: 115,
              backdropEnabled: true,
              backdropTapClosesPanel: true,
              boxShadow: const [],
              controller: slidingUpPanelController,
              onPanelSlide: (position) {
                _panelSlide.value = position;
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
                child: RefreshIndicator(
                  onRefresh: _handleRefresh,
                  color: Theme.of(context).primaryColor,
                  child: Scrollbar(
                  child: CustomScrollView(
                    physics: const PositionRetainedScrollPhysics().applyTo(const AlwaysScrollableScrollPhysics()),
                    cacheExtent: 300.0,
                    slivers: <Widget>[
                    SliverAppBar(
                      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                      flexibleSpace: FlexibleSpaceBar(
                        background: Container(color: Theme.of(context).scaffoldBackgroundColor),
                      ),
                      floating: true,
                      centerTitle: true,
                      toolbarHeight: 75,
                      automaticallyImplyLeading: false,
                      title: Container(
                          margin: const EdgeInsets.only(top: 6),
                          child: const Row(
                            children: [
                              Image(
                                image: AssetImage('assets/icons/ic_logo_filled.png'),
                                width: 40,
                              ),
                              SizedBox(width: 10),
                              Text(
                                "Radio Creștin",
                                style: TextStyle(fontSize: 21),
                              ),
                            ],
                          )),
                      actions: [
                        const SizedBox(width: 4),
                        _buildRoundedIconButton(
                          context: context,
                          icon: Icons.search_rounded,
                          tooltip: 'Caută o stație radio',
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return SelectDialog<Station>(
                                  items: stations,
                                  displayFunction: (Station station) => station.displayTitle,
                                  searchFunction: (Station station) => station.displayTitle,
                                  onItemSelected: (Station station) {
                                    _audioHandler.playStation(station, playlist: stations);
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
                          onPressed: () async {
                            await Navigator.push(context, MaterialPageRoute<void>(
                              builder: (BuildContext context) {
                                return const SettingsPage();
                              },
                            ));
                            // Check share promotion visibility after returning from settings
                            if (mounted) {
                              await _checkSharePromotionVisibility();
                              await _loadShareLinkData();
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                    if (_showSharePromotion)
                      SliverToBoxAdapter(
                        child: SharePromotionCard(
                          key: _sharePromotionKey,
                          client: _audioHandler.graphqlClient,
                          currentStationSlug: currentStation?.slug,
                          currentStationName: currentStation?.title,
                          onClose: () async {
                            // Update local state immediately
                            setState(() {
                              _showSharePromotion = false;
                            });
                            // Save to preferences
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
                              isFavoritesPlaylist: true,
                            )),
                      ),
                    if (stations.isNotEmpty)
                      SliverStickyHeader(
                        header: Container(
                          height: 60.0,
                          color: Theme.of(context).scaffoldBackgroundColor,
                          padding: const EdgeInsets.only(left: 16.0, right: 4.0),
                          alignment: Alignment.centerLeft,
                          child: Row(
                            children: [
                              // Sort dropdown
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => _showSortOptions(context),
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
                              // Filter icon button
                              _buildRoundedIconButton(
                                context: context,
                                icon: selectedStationGroup != null
                                    ? Icons.filter_alt_rounded
                                    : Icons.filter_alt_outlined,
                                tooltip: selectedStationGroup?.name ?? 'Filtrează',
                                isActive: selectedStationGroup != null,
                                onPressed: () => _showFilterOptions(context, stationGroups, selectedStationGroup),
                              ),
                            ],
                          ),
                        ),
                        sliver: SliverPadding(
                            padding: EdgeInsets.only(bottom: Platform.isIOS ? 80.0 : 110.0),
                            sliver: StationsList(
                              stations: filteredStations,
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
              collapsed: currentStation != null && stations.isNotEmpty
                  ? Container(
                      padding: EdgeInsets.only(bottom: Platform.isIOS ? 20 : 12, left: 8, right: 8),
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
            );
          }),
    );
  }

  playByStationSlug(String stationSlug) async {
    developer.log("playByStationSlug:$stationSlug");
    await waitForStationsUpdate();
    var stations = await _audioHandler.stationsMediaItems.first;
    var station = stations.where((item) => item.extras?['station_slug'] == stationSlug).firstOrNull;
    if (station != null) {
      developer.log("found station:$station");
      await _audioHandler.playMediaItem(station);
    } else {
      developer.log("station not found:$stationSlug");
    }
  }

  Future<void> waitForStationsUpdate() {
    if (_stationDataService.stations.value.isNotEmpty) return Future.value();
    return _stationDataService.stations.stream
        .firstWhere((stations) => stations.isNotEmpty);
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

      // Determine playlist context based on whether the station is a favorite
      final favSlugs = _stationDataService.favoriteStationSlugs.value.toSet();
      final isFav = favSlugs.contains(station.slug);
      final playlist = isFav
          ? _stationDataService.filteredStations.value
                .where((s) => favSlugs.contains(s.slug))
                .toList()
          : _stationDataService.filteredStations.value;

      if (autoStart) {
        _audioHandler.playStation(station, playlist: playlist, isFavoritesPlaylist: isFav);
      } else {
        _audioHandler.selectStation(station, playlist: playlist, isFavoritesPlaylist: isFav);
      }
    }
  }
}
