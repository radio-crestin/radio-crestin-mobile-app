import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
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
import '../main.dart';
import '../queries/getStations.graphql.dart';
import '../types/Station.dart';
import '../utils/PositionRetainedScrollPhysics.dart';
import '../globals.dart' as globals;
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
  final MediaItem? mediaItem;
  final bool isDraggable;
  final List<String> favoriteSlugs;

  const HomePageState(
    this.currentStation,
    this.stations,
    this.filteredStations,
    this.stationGroups,
    this.selectedStationGroup,
    this.mediaItem,
    this.isDraggable,
    this.favoriteSlugs,
  );
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late StreamSubscription _sub;
  CustomPanelController slidingUpPanelController = CustomPanelController();

  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();
  final AppLinks _appLinks = AppLinks();

  var autoPlayProcessed = false;
  bool _showSharePromotion = false;
  final GlobalKey<SharePromotionCardState> _sharePromotionKey = GlobalKey();
  ShareLinkData? _shareLinkData;
  bool _isLoadingShareData = true;

  _HomePageState() {
    _appLinks.getInitialLink().then((uri) {
      processIntentUri(uri);
    });

    _sub = _appLinks.uriLinkStream.listen((Uri? uri) {
      processIntentUri(uri);
    }, onError: (err) {
      developer.log("initialLink err:" + err.toString());
    });


  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkSharePromotionVisibility();
    _loadShareLinkData();
    _showCarPlayAnnouncementIfNeeded();
  }

  Future<void> _showCarPlayAnnouncementIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeenCarPlay = prefs.getBool('has_seen_carplay_announcement1') ?? false;

    if (!hasSeenCarPlay && globals.appVersion == '1.3.2') {
      // Wait for the widget to be built before showing dialog
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showCarPlayDialog();
      });
    }
  }

  void _showCarPlayDialog() async {
    final prefs = await SharedPreferences.getInstance();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final accentColor = isDark ? const Color(0xFFEBB800) : const Color(0xFFFF6B35);
        final bottomPadding = MediaQuery.of(context).padding.bottom;

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + bottomPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.directions_car_filled_rounded,
                  size: 44,
                  color: accentColor,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Noutate: Apple CarPlay',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Acum poți asculta Radio Creștin direct din mașină! '
                'Conectează-ți telefonul la Apple CarPlay '
                'și bucură-te de stațiile tale preferate în siguranță, la volan.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.apple, size: 20, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
                  const SizedBox(width: 4),
                  Text(
                    'CarPlay',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Am înțeles',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    await prefs.setBool('has_seen_carplay_announcement1', true);
  }

  Future<void> _handleRefresh() async {
    try {
      // Refresh stations
      await _audioHandler.refreshStations();
      
      // Refresh share promotion visibility
      await _checkSharePromotionVisibility();
      
      // Refresh share link data
      await _loadShareLinkData();
      
      // Refresh share promotion card if it's visible
      if (_showSharePromotion && _sharePromotionKey.currentState != null) {
        await _sharePromotionKey.currentState!.refreshShareLink();
      }
    } catch (e) {
      developer.log('Error refreshing: $e');
    }
  }

  Future<void> _checkSharePromotionVisibility() async {
    final prefs = await SharedPreferences.getInstance();
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
      final prefs = await SharedPreferences.getInstance();
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      try {
        final isPlaying = (await _audioHandler.playbackState.first).playing;
        if (!isPlaying) {
          autoPlayProcessed = false;
          playerAutoplay();
        }
      } catch (e) {
        developer.log('Error autoplaying on resume: $e');
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
      final prefs = await SharedPreferences.getInstance();
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
        final shareUrl = shareLinkData.generateShareUrl();
        final shareMessage = ShareUtils.formatShareMessage(
          shareLinkData: shareLinkData,
          stationName: null,
          stationSlug: null,
        );
        
        // Show dialog with share options
        if (mounted) {
          ShareHandler.shareApp(
            context: context,
            shareUrl: shareUrl,
            shareMessage: shareMessage,
            shareLinkData: shareLinkData,
            showDialog: true,
          );
        }
      }
    } catch (e) {
      // Fallback to old method if something fails
      if (mounted) {
        ShareHandler.shareApp(
          context: context,
          shareUrl: 'https://asculta.radiocrestin.ro',
          shareMessage: 'Aplicația Radio Creștin:\nhttps://asculta.radiocrestin.ro',
          showDialog: false, // Direct share for fallback
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
          stream: Rx.combineLatest8<
              Station?,
              List<Station>,
              List<Station>,
              List<Query$GetStations$station_groups>,
              Query$GetStations$station_groups?,
              MediaItem?,
              bool,
              List<String>,
              HomePageState>(
            _audioHandler.currentStation.stream,
            _audioHandler.stations.stream,
            _audioHandler.filteredStations.stream,
            _audioHandler.stationGroups,
            _audioHandler.selectedStationGroup.stream,
            _audioHandler.mediaItem,
            slidingUpPanelController.isDraggableSubject,
            _audioHandler.favoriteStationSlugs.stream,
            (currentStation, stations, filteredStations, stationGroups, selectedStationGroup,
                    mediaItem, isDraggable, favoriteSlugs) =>
                HomePageState(currentStation, stations, filteredStations, stationGroups,
                    selectedStationGroup, mediaItem, isDraggable, favoriteSlugs),
          ),
          builder: (context, snapshot) {
            final currentStation = snapshot.data?.currentStation;
            final stations = snapshot.data?.stations ?? [];
            final stationGroups = snapshot.data?.stationGroups ?? [];
            final isDraggable = snapshot.data?.isDraggable ?? true;
            final selectedStationGroup = snapshot.data?.selectedStationGroup;
            final filteredStations = snapshot.data?.filteredStations ?? [];
            final favoriteSlugs = snapshot.data?.favoriteSlugs ?? [];

            final favoriteStations = stations.where((station) => favoriteSlugs.contains(station.slug)).toList();
            final isLoading = stations.isEmpty;

            // Show centered loading indicator when stations are loading
            if (isLoading) {
              return Scaffold(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                appBar: AppBar(
                  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                  elevation: 0,
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
                    ),
                  ),
                ),
                body: Container(
                  padding: const EdgeInsets.only(top: 180),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        CircularProgressIndicator(
                          color: Theme.of(context).primaryColor,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          "Stațiile se încarcă...",
                          style: TextStyle(
                            fontSize: 16,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            return SlidingUpPanel(
              maxHeight: panelMaxHeight,
              // minHeight: 115,
              backdropEnabled: true,
              backdropTapClosesPanel: true,
              boxShadow: const [],
              controller: slidingUpPanelController,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16.0),
                topRight: Radius.circular(16.0),
              ),
              isDraggable: (slidingUpPanelController.isAttached &&
                      (slidingUpPanelController.isPanelClosed ||
                          slidingUpPanelController.isPanelClosed)) ||
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
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 600),
                          transitionBuilder: (Widget child, Animation<double> animation) {
                            return ScaleTransition(
                              scale: Tween<double>(
                                begin: 0.3,
                                end: 1.0,
                              ).animate(CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeOutBack,
                              )),
                              child: child,
                            );
                          },
                          child: _shareLinkData != null && _shareLinkData!.visitCount != null
                            ? Container(
                              key: ValueKey('share-badge'),
                              margin: const EdgeInsets.only(right: 4),
                              child: InkWell(
                                onTap: () {
                                  _shareApp(context);
                                },
                                borderRadius: BorderRadius.circular(20),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: (Theme.of(context).brightness == Brightness.light
                                        ? const Color(0xFFFF6B35) // Orange for light theme
                                        : const Color(0xFFffc700)).withOpacity(0.12), // Yellow for dark theme
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: (Theme.of(context).brightness == Brightness.light
                                          ? const Color(0xFFFF6B35)
                                          : const Color(0xFFffc700)).withOpacity(0.3),
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _formatVisitCount(_shareLinkData!.visitCount),
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Theme.of(context).brightness == Brightness.light
                                              ? const Color(0xFFFF6B35) // Orange for light theme
                                              : const Color(0xFFffc700), // Yellow for dark theme
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Icon(
                                        Icons.people_outline_rounded,
                                        size: 18,
                                        color: Theme.of(context).brightness == Brightness.light
                                            ? const Color(0xFFFF6B35) // Orange for light theme
                                            : const Color(0xFFffc700), // Yellow for dark theme
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            : SizedBox.shrink(key: ValueKey('empty')),
                        ),
                        IconButton(
                          icon: const Icon(Icons.search),
                          color: Theme.of(context).colorScheme.onSurface,
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
                                    _audioHandler.playStation(station);
                                  },
                                );
                              },
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings),
                          color: Theme.of(context).colorScheme.onSurface,
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
                            final prefs = await SharedPreferences.getInstance();
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
                            )),
                      ),
                    if (stations.isNotEmpty)
                      SliverStickyHeader(
                        header: Container(
                          height: 60.0,
                          color: Theme.of(context).scaffoldBackgroundColor,
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          alignment: Alignment.centerLeft,
                          child: Row(
                            children: [
                              Text(
                                selectedStationGroup?.name ?? "Toate stațiile radio",
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurface),
                              ),
                              const Spacer(),
                              TextButton(
                                  onPressed: () {
                                    showDialog(
                                      context: context,
                                      builder: (BuildContext context) {
                                        final stationGroupOptions = [
                                          Query$GetStations$station_groups(
                                            id: -1,
                                            name: 'Toate stațiile radio',
                                            order: -1,
                                            slug: 'all-stations',
                                            station_to_station_groups: [],
                                          ),
                                          ...stationGroups
                                            ..sort((a, b) => a.order.compareTo(b.order))
                                        ];
                                        return SelectDialog<Query$GetStations$station_groups>(
                                          items: stationGroupOptions,
                                          displayFunction:
                                              (Query$GetStations$station_groups stationGroup) =>
                                                  stationGroup.name,
                                          onItemSelected:
                                              (Query$GetStations$station_groups stationGroup) {
                                            setState(() {
                                              if (stationGroup.slug == 'all-stations') {
                                                _audioHandler.selectedStationGroup.add(null);
                                              } else {
                                                _audioHandler.selectedStationGroup
                                                    .add(stationGroup);
                                              }
                                            });
                                          },
                                        );
                                      },
                                    );
                                  },
                                  child: Text(
                                    "Filtrează",
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Theme.of(context).colorScheme.primary),
                                  ))
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

  waitForStationsUpdate() async {
    while (true) {
      if (_audioHandler.stations.value.isNotEmpty) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
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
      final prefs = await SharedPreferences.getInstance();
      final autoStart = prefs.getBool('_autoStartStation') ?? true;
      var station = await _audioHandler.getLastPlayedStation();
      if (autoStart) {
        _audioHandler.playStation(station);
      } else {
        _audioHandler.selectStation(station);
      }
    }
  }
}
