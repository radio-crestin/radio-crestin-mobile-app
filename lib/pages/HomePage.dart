import 'dart:async';
import 'dart:developer' as developer;

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:audio_service/audio_service.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:is_tv/is_tv.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sliding_up_panel/sliding_up_panel.dart';
import 'package:uni_links_nfc_support/uni_links_nfc_support.dart';

import '../components/TvStationsList.dart';
import '../main.dart';
import '../queries/getStations.graphql.dart';
import '../types/Station.dart';
import '../utils.dart';
import '../utils/PositionRetainedScrollPhysics.dart';

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
  final String? currentImageBackgroundSrc;
  final Station? currentStation;
  final Station? focusedStation;
  final List<Station> stations;
  final List<Station> filteredStations;
  final List<Query$GetStations$station_groups> stationGroups;
  final Query$GetStations$station_groups? selectedStationGroup;
  final MediaItem? mediaItem;
  final bool isDraggable;

  const HomePageState(
    this.currentImageBackgroundSrc,
    this.currentStation,
    this.focusedStation,
    this.stations,
    this.filteredStations,
    this.stationGroups,
    this.selectedStationGroup,
    this.mediaItem,
    this.isDraggable,
  );
}

class _HomePageState extends State<HomePage> {
  bool? _isTV;
  final _isTVPlugin = IsTV();

  late StreamSubscription _sub;
  CustomPanelController slidingUpPanelController = CustomPanelController();

  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();

  _HomePageState() {
    try {
      AndroidPlayInstallReferrer.installReferrer.then((value) {
        developer.log("AndroidPlayInstallReferrer:$value");
        if (value.installReferrer != null) {
          playByStationSlug(value.installReferrer!);
        }
      });
    } catch (e) {
      developer.log("AndroidPlayInstallReferrer err:$e");
    }

    getInitialUri().then((value) => {processIntentUri(value)});

    _sub = uriLinkStream.listen((Uri? uri) {
      processIntentUri(uri);
    }, onError: (err) {
      developer.log("initialLink err:$err");
    });
  }

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  Future<void> initPlatformState() async {
    bool? isTV;

    try {
      isTV = await _isTVPlugin.check() ?? false;
    } on PlatformException {
      isTV = false;
    }

    if (!mounted) return;

    setState(() {
      _isTV = isTV ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    double panelMaxHeight = MediaQuery.of(context).size.height * .9;

    if (_isTV == true || true) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: StreamBuilder<HomePageState>(
            stream: Rx.combineLatest9<
                String?,
                Station?,
                Station?,
                List<Station>,
                List<Station>,
                List<Query$GetStations$station_groups>,
                Query$GetStations$station_groups?,
                MediaItem?,
                bool,
                HomePageState>(
              _audioHandler.currentImageBackgroundSrc.stream,
              _audioHandler.currentStation.stream,
              _audioHandler.focusedStation.stream,
              _audioHandler.stations.stream,
              _audioHandler.filteredStations.stream,
              _audioHandler.stationGroups,
              _audioHandler.selectedStationGroup.stream,
              _audioHandler.mediaItem,
              slidingUpPanelController.isDraggableSubject,
              (currentImageBackgroundSrc,
                      currentStation,
                      focusedStation,
                      stations,
                      filteredStations,
                      stationGroups,
                      selectedStationGroup,
                      mediaItem,
                      isDraggable) =>
                  HomePageState(
                currentImageBackgroundSrc,
                currentStation,
                focusedStation,
                stations,
                filteredStations,
                stationGroups,
                selectedStationGroup,
                mediaItem,
                isDraggable,
              ),
            ),
            builder: (context, snapshot) {
              // final currentImageBackgroundSrc = snapshot.data?.currentImageBackgroundSrc;
              const currentImageBackgroundSrc =
                  'https://images.unsplash.com/photo-1619903774373-7dea6886db8e?ixid=MnwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8&ixlib=rb-1.2.1&auto=format&fit=crop&w=774&q=80';
              final currentStation = snapshot.data?.currentStation;
              final focusedStation = snapshot.data?.focusedStation;
              final stations = snapshot.data?.stations ?? [];
              final filteredStations = snapshot.data?.filteredStations ?? [];

              final favoriteStations = stations.where((station) => station.isFavorite).toList();

              return SizedBox(
                width: double.infinity, // 100% width
                height: double.infinity,
                child: Stack(
                  children: [

                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withOpacity(0.8),
                              Colors.transparent, // Fully transparent
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: Utils.displayImage(currentImageBackgroundSrc, cache: false),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 20,
                      height: 220,
                      child: CustomScrollView(
                        physics: const PositionRetainedScrollPhysics(),
                        cacheExtent: 220.0,
                        scrollDirection: Axis.horizontal,
                        slivers: <Widget>[
                          if (favoriteStations.isNotEmpty)
                            TvStationsList(
                              stations: favoriteStations,
                              currentStation: currentStation,
                              focusedStation: focusedStation,
                              audioHandler: _audioHandler,
                              panelController: null,
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
                            TvStationsList(
                              stations: filteredStations,
                              currentStation: currentStation,
                              focusedStation: focusedStation,
                              audioHandler: _audioHandler,
                              panelController: null,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
      );
    }
  }

  @override
  void dispose() {
    super.dispose();
    _sub.cancel();
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
}

class ImageCard extends StatelessWidget {
  final bool selected;
  final bool focus;
  final String image;

  const ImageCard({
    super.key,
    required this.selected,
    required this.image,
    required this.focus,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: focus ? Colors.white : Colors.black,
          border: Border.all(
            color: focus ? Colors.white : (selected ? Colors.blue.shade400 : Colors.black),
            width: 5,
          ),
          image: DecorationImage(image: NetworkImage(image), fit: BoxFit.cover),
        ),
      ),
    );
  }
}
