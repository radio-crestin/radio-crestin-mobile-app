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
import 'package:sliding_up_panel/sliding_up_panel.dart';

import '../components/MiniAudioPlayer.dart';
import '../components/SelectDialog.dart';
import '../components/StationsList.dart';
import '../main.dart';
import '../queries/getStations.graphql.dart';
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
  final MediaItem? mediaItem;
  final bool isDraggable;

  const HomePageState(
    this.currentStation,
    this.stations,
    this.filteredStations,
    this.stationGroups,
    this.selectedStationGroup,
    this.mediaItem,
    this.isDraggable,
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
    _checkSharePromotionVisibility();
    _loadShareLinkData();
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
    _sub.cancel();
    super.dispose();
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
          stream: Rx.combineLatest7<
              Station?,
              List<Station>,
              List<Station>,
              List<Query$GetStations$station_groups>,
              Query$GetStations$station_groups?,
              MediaItem?,
              bool,
              HomePageState>(
            _audioHandler.currentStation.stream,
            _audioHandler.stations.stream,
            _audioHandler.filteredStations.stream,
            _audioHandler.stationGroups,
            _audioHandler.selectedStationGroup.stream,
            _audioHandler.mediaItem,
            slidingUpPanelController.isDraggableSubject,
            (currentStation, stations, filteredStations, stationGroups, selectedStationGroup,
                    mediaItem, isDraggable) =>
                HomePageState(currentStation, stations, filteredStations, stationGroups,
                    selectedStationGroup, mediaItem, isDraggable),
          ),
          builder: (context, snapshot) {
            final currentStation = snapshot.data?.currentStation;
            final stations = snapshot.data?.stations ?? [];
            final stationGroups = snapshot.data?.stationGroups ?? [];
            final isDraggable = snapshot.data?.isDraggable ?? true;
            final selectedStationGroup = snapshot.data?.selectedStationGroup;
            final filteredStations = snapshot.data?.filteredStations ?? [];

            final favoriteStations = stations.where((station) => station.isFavorite).toList();
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
              gestureSlidingEnabled: (slidingUpPanelController.isAttached &&
                      (slidingUpPanelController.isPanelClosed ||
                          slidingUpPanelController.isPanelClosed)) ||
                  isDraggable,
              body: SafeArea(
                child: RefreshIndicator(
                  onRefresh: _handleRefresh,
                  color: Theme.of(context).primaryColor,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
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
                        if (_shareLinkData != null && _shareLinkData!.visitCount > 0)
                          InkWell(
                            onTap: () {
                              _shareApp(context);
                            },
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              margin: const EdgeInsets.only(right: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00ACC1).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: const Color(0xFF00ACC1).withOpacity(0.3),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.people_outline_rounded,
                                    size: 18,
                                    color: const Color(0xFF00ACC1),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${_shareLinkData!.visitCount}',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF00ACC1),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          IconButton(
                            icon: const Icon(Icons.bolt),
                            color: const Color(0xFF00ACC1),
                            tooltip: 'Distribuie aplicația',
                            onPressed: () {
                              _shareApp(context);
                            },
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
                            )),
                      ),
                  ],
                  ),
                ),
              ),
              collapsed: currentStation != null && stations.isNotEmpty
                  ? Container(
                      padding: EdgeInsets.only(bottom: Platform.isIOS ? 17 : 12, left: 8, right: 8),
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: MiniAudioPlayer(
                        currentStation: currentStation,
                        audioHandler: _audioHandler,
                        panelController: slidingUpPanelController,
                      ),
                    )
                  : null,
              panel: Container(
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
