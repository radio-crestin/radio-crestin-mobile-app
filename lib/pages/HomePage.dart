import 'dart:async';
import 'dart:developer' as developer;

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:audio_service/audio_service.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/FullAudioPlayer.dart';
import 'package:radio_crestin/components/QueueList.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sliding_up_panel/sliding_up_panel.dart';
import 'package:uni_links_nfc_support/uni_links_nfc_support.dart';
import 'package:upgrader/upgrader.dart';

import '../components/MiniAudioPlayer.dart';
import '../main.dart';

final remoteConfig = FirebaseRemoteConfig.instance;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late StreamSubscription _sub;
  PanelController panelController = PanelController();

  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();

  playByStationSlug(String stationSlug) async {
    developer.log("playByStationSlug:" + stationSlug);
    var stations = await _audioHandler.stationsMediaItems.first;
    var station = stations.where((item) => item.extras?['station_slug'] == stationSlug).firstOrNull;
    if (station != null) {
      developer.log("found station:$station");
      _audioHandler.playMediaItem(station);
    }
  }

  processIntentUri(Uri? uri) async {
    try {
      if (uri == null) {
        return;
      }
      developer.log("processIntentUri:" + uri.toString());
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

  /// A stream reporting the combined state of the current queue and the current
  /// media item within that queue.
  Stream<QueueState> get _queueStateStream =>
      Rx.combineLatest2<List<MediaItem>, MediaItem?, QueueState>(_audioHandler.stationsMediaItems,
          _audioHandler.mediaItem, (queue, mediaItem) => QueueState(queue, mediaItem));

  @override
  Widget build(BuildContext context) {
    double panelMaxHeight = MediaQuery.of(context).size.height * .75;

    return UpgradeAlert(
        upgrader: Upgrader(showIgnore: false),
        child: Scaffold(
            appBar: AppBar(
              // backgroundColor: Colors.white,
              elevation: 0,
              leading: const Center(
                child: Image(
                  image: AssetImage('assets/icons/ic_foreground.png'),
                  width: 30,
                  height: 30,
                ),
              ),
              title: Container(
                // transform: Matrix4.translationValues(-16, 0, 0.0),
                child: const Text('Radio Crestin'),
              ),
              titleTextStyle: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              actions: <Widget>[
                IconButton(
                  icon: const Icon(
                    Icons.settings,
                    color: Colors.white,
                  ),
                  tooltip: 'Setari aplicatie',
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
            body: StreamBuilder<QueueState>(
                stream: _queueStateStream,
                builder: (context, snapshot) {
                  final queue = snapshot.data?.stationsMediaItems ?? [];
                  final mediaItem = snapshot.data?.mediaItem;
                  return SlidingUpPanel(
                    maxHeight: panelMaxHeight,
                    // minHeight: 115,
                    backdropEnabled: true,
                    // color: Theme.of(context).bottomAppBarTheme.color!,
                    controller: panelController,
                    body: QueueList(
                      queue: queue,
                      mediaItem: mediaItem,
                      audioHandler: _audioHandler,
                      scrollController: null,
                      panelController: null,
                    ),
                    collapsed: MiniAudioPlayer(
                      mediaItem: mediaItem,
                      audioHandler: _audioHandler,
                      panelController: panelController,
                    ),
                    panelBuilder: (sc) => Container(
                      decoration: const BoxDecoration(
                        color: Colors.transparent, // Set the background color to transparent
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(16.0),
                          topRight: Radius.circular(16.0),
                        ),
                      ),
                      child: FullAudioPlayer(
                        mediaItem: mediaItem,
                        audioHandler: _audioHandler,
                      ),
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16.0),
                      topRight: Radius.circular(16.0),
                    ),
                    margin: const EdgeInsets.symmetric(horizontal: 4.0),
                  );
                })));
  }

  @override
  void dispose() {
    // Clean up resources, subscriptions, controllers, etc.
    super.dispose();
    _sub.cancel();
  }
}
