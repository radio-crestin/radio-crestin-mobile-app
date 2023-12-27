import 'dart:async';
import 'dart:developer' as developer;

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:audio_service/audio_service.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sticky_header/flutter_sticky_header.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/FullAudioPlayer.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sliding_up_panel/sliding_up_panel.dart';
import 'package:uni_links_nfc_support/uni_links_nfc_support.dart';

import '../components/MiniAudioPlayer.dart';
import '../components/SearchDialog.dart';
import '../main.dart';
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
  final List<MediaItem> stationsMediaItems;
  final MediaItem? mediaItem;
  final bool isDraggable;

  const HomePageState(this.stationsMediaItems, this.mediaItem, this.isDraggable);
}

class _HomePageState extends State<HomePage> {
  late StreamSubscription _sub;
  CustomPanelController slidingUpPanelController = CustomPanelController();

  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();

  _HomePageState() {
    try {
      AndroidPlayInstallReferrer.installReferrer.then((value) {
        developer.log("AndroidPlayInstallReferrer:" + value.toString());
        if (value.installReferrer != null) {
          playByStationSlug(value.installReferrer!);
        }
      });
    } catch (e) {
      developer.log("AndroidPlayInstallReferrer err:" + e.toString());
    }

    getInitialUri().then((value) => {processIntentUri(value)});

    _sub = uriLinkStream.listen((Uri? uri) {
      processIntentUri(uri);
    }, onError: (err) {
      developer.log("initialLink err:" + err.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    double panelMaxHeight = MediaQuery.of(context).size.height * .82;

    return Scaffold(
      body: StreamBuilder<HomePageState>(
          stream: Rx.combineLatest3<List<MediaItem>, MediaItem?, bool, HomePageState>(
            _audioHandler.stationsMediaItems,
            _audioHandler.mediaItem,
            slidingUpPanelController.isDraggableSubject,
            (stationsMediaItems, mediaItem, isDraggable) => HomePageState(stationsMediaItems, mediaItem, isDraggable),
          ),
          builder: (context, snapshot) {
            final stationsMediaItems = snapshot.data?.stationsMediaItems ?? [];
            final mediaItem = snapshot.data?.mediaItem;
            final isDraggable = snapshot.data?.isDraggable ?? true;
            final favoriteStations = stationsMediaItems.where((s) => s.extras?['is_favorite'] == 'true').toList();

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
              gestureSlidingEnabled: (slidingUpPanelController.isAttached && (slidingUpPanelController.isPanelClosed || slidingUpPanelController.isPanelClosed)) || isDraggable,
              body: SafeArea(
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(),
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
                                style: TextStyle(
                                    fontSize: 21
                                ),
                              ),
                            ],
                          )
                      ),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.search),
                          color: Colors.grey[800],
                          tooltip: 'Caută o stație radio',
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return SearchDialog(
                                  stationsMediaItems: stationsMediaItems,
                                  audioHandler: _audioHandler,
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
                    if(favoriteStations.isNotEmpty)  SliverStickyHeader(
                      header: Container(
                        height: 60.0,
                        color: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Favorite',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey[800]),
                        ),
                      ),
                      sliver: StationsList(
                        stationsMediaItems: favoriteStations,
                        mediaItem: mediaItem,
                        audioHandler: _audioHandler,
                        panelController: null,
                      ),
                    ),

                    SliverStickyHeader(
                      header: Container(
                        height: 60.0,
                        color: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Toate stațiile radio',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey[800]),
                        ),
                      ),
                      sliver: SliverPadding(
                          padding: const EdgeInsets.only(bottom: 110.0),
                          sliver: StationsList(
                            stationsMediaItems: stationsMediaItems,
                            mediaItem: mediaItem,
                            audioHandler: _audioHandler,
                            panelController: null,
                          )
                      ),
                    ),
                    // SliverToBoxAdapter(
                    //   child: Padding(
                    //     padding: const EdgeInsets.only(left: 16.0, right: 16, bottom: 12, top: 24),
                    //     child: Text('Toate stațiile radio', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey[800])),
                    //   ),
                    // ),
                    // SliverPadding(
                    //     padding: const EdgeInsets.only(bottom: 110.0),
                    //     sliver: StationsList(
                    //       stationsMediaItems: stationsMediaItems,
                    //       mediaItem: mediaItem,
                    //       audioHandler: _audioHandler,
                    //       panelController: null,
                    //     )
                    // ),
                  ],
                ),
              ),
              collapsed: Container(
                padding: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
                color: Theme.of(context).scaffoldBackgroundColor,
                child: MiniAudioPlayer(
                  mediaItem: mediaItem,
                  audioHandler: _audioHandler,
                  panelController: slidingUpPanelController,
                ),
              ),
              panelBuilder: (sc) => Container(
                decoration: const BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16.0),
                    topRight: Radius.circular(16.0),
                  ),
                ),
                child: FullAudioPlayer(
                  audioHandler: _audioHandler,
                  slidingUpPanelController: slidingUpPanelController,
                ),
              ),
            );
          }),
    );
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
