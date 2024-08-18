import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/FullAudioPlayer.dart';
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

final remoteConfig = FirebaseRemoteConfig.instance;

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      playerAutoplay();
    }
  }


  @override
  Widget build(BuildContext context) {
    double panelMaxHeight = MediaQuery.of(context).size.height * .9;

    return Scaffold(
      backgroundColor: Colors.white,
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
                child: CustomScrollView(
                  physics: const PositionRetainedScrollPhysics(),
                  cacheExtent: 300.0,
                  slivers: <Widget>[
                    SliverAppBar(
                      flexibleSpace: FlexibleSpaceBar(
                        background: Container(color: const Color(0xfffafafa)),
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
                        IconButton(
                          icon: const Icon(Icons.search),
                          color: Colors.grey[800],
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
                          color: Colors.grey[800],
                          tooltip: 'Setări aplicație',
                          onPressed: () {
                            Navigator.push(context, MaterialPageRoute<void>(
                              builder: (BuildContext context) {
                                return SettingsPage();
                              },
                            ));
                          },
                        ),
                      ],
                    ),
                    if (favoriteStations.isNotEmpty)
                      SliverStickyHeader(
                        header: Container(
                          height: 60.0,
                          color: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Favorite',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey[800]),
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
                    if (stations.isEmpty)
                      SliverToBoxAdapter(
                        child: Container(
                          margin: const EdgeInsets.all(16),
                          child: const Text(
                            "Statiile se incarca..",
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                    if (stations.isNotEmpty)
                      SliverStickyHeader(
                        header: Container(
                          height: 60.0,
                          color: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          alignment: Alignment.centerLeft,
                          child: Row(
                            children: [
                              Text(
                                selectedStationGroup?.name ?? "Toate stațiile radio",
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey[800]),
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
                                        color: Colors.blue[700]),
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
              collapsed: currentStation != null
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
    var stations = await _audioHandler.stationsMediaItems.first;
    var station = stations.where((item) => item.extras?['station_slug'] == stationSlug).firstOrNull;
    if (station != null) {
      developer.log("found station:$station");
      await _audioHandler.playMediaItem(station);
    }
  }

  processIntentUri(Uri? uri) async {
    try {
      if (uri == null) {
        return;
      }
      developer.log("processIntentUri:$uri");
      var stationSlug =
          uri.path.replaceAll("/share/", "").replaceAll("/radio/", "").replaceAll("/", "");
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
