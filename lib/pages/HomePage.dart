import 'dart:async';
import 'dart:developer' as developer;

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:audio_service/audio_service.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/BottomNavigationAudioPlayer.dart';
import 'package:radio_crestin/components/QueueList.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uni_links_nfc_support/uni_links_nfc_support.dart';
import 'package:upgrader/upgrader.dart';

import '../main.dart';

final remoteConfig = FirebaseRemoteConfig.instance;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late StreamSubscription _sub;
  late ScrollController _hideButtonController;

  bool _isVisible = false;
  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();

  playByStationSlug(String stationSlug) async {
    developer.log("playByStationSlug:" + stationSlug);
    var stations = await _audioHandler.stationsMediaItems.first;
    var station = stations.where((item) => item.extras?['station_slug'] == stationSlug).firstOrNull;
    if(station != null) {
      developer.log("found station:$station");
      _audioHandler.playMediaItem(station);
    }
  }
  processIntentUri(Uri? uri) async {
    try {
      if(uri == null) {
        return;
      }
      developer.log("processIntentUri:" + uri.toString());
      var stationSlug = uri.path.replaceAll("/share/", "").replaceAll("/radio/", "").replaceAll("/", "");
      if(stationSlug == "") {
        stationSlug = uri.host;
      }
      playByStationSlug(stationSlug);

    } catch(e) {
      developer.log("processIntentUri error:$e");
    }
  }

  _HomePageState() {
    try {
      AndroidPlayInstallReferrer.installReferrer.then((value) {
        developer.log("AndroidPlayInstallReferrer:" + value.toString());
        if(value.installReferrer != null) {
          playByStationSlug(value.installReferrer!);
        }
      });
    } catch(e) {
      developer.log("AndroidPlayInstallReferrer err:" + e.toString());
    }

    getInitialUri().then((value) => {
      processIntentUri(value)
    });

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
  initState() {
    super.initState();
    _isVisible = true;
    _hideButtonController = ScrollController();
    _hideButtonController.addListener(() {
      if (_hideButtonController.position.userScrollDirection == ScrollDirection.reverse) {
        if (_isVisible) {
          setState(() {
            _isVisible = false;
          });
        }
      }
      if (_hideButtonController.position.userScrollDirection == ScrollDirection.forward) {
        if (!_isVisible) {
          setState(() {
            _isVisible = true;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return UpgradeAlert(
        upgrader: Upgrader(showIgnore: false),
        child: Scaffold(
            appBar: AppBar(
              leading: const Center(
                  child: Image(
                      image: AssetImage('assets/icons/ic_foreground.png'), width: 30, height: 30)),
              title: Container(
                child: const Text('Radio Crestin'),
                transform: Matrix4.translationValues(-16, 0, 0.0),
              ),
              titleTextStyle: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              actions: <Widget>[
                // IconButton(
                //   icon: const Icon(Icons.add_alert),
                //   tooltip: 'Show Snackbar',
                //   onPressed: () {
                //     ScaffoldMessenger.of(context).showSnackBar(
                //         const SnackBar(content: Text('This is a snackbar')));
                //   },
                // ),
                StreamBuilder<QueueState>(
                  stream: _queueStateStream,
                  builder: (context, snapshot) {
                    final mediaItem = snapshot.data?.mediaItem;
                    developer.log("mediaItem" + mediaItem.toString());
                    return IconButton(
                      icon: const Icon(Icons.campaign),
                      tooltip: 'Trimite aplicatia prietenilor tai',
                      onPressed: () {
                        if(mediaItem != null) {
                          var linkMessage = "";
                          linkMessage += "${mediaItem.title}\n";
                          linkMessage += "https://share.radiocrestin.ro/${mediaItem.extras?['station_slug']}";

                          Share.share(remoteConfig.getString("share_app_station_message") + linkMessage);
                        } else {
                          Share.share(remoteConfig.getString("share_app_message"));
                        }
                      },
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
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
            body: Stack(
              children: [
                StreamBuilder<QueueState>(
                  stream: _queueStateStream,
                  builder: (context, snapshot) {
                    final queue = snapshot.data?.stationsMediaItems ?? [];
                    final mediaItem = snapshot.data?.mediaItem;
                    return QueueList(
                      queue: queue,
                      mediaItem: mediaItem,
                      audioHandler: _audioHandler,
                      hideButtonController: _hideButtonController,
                    );
                  },
                ),
                StreamBuilder<QueueState>(
                  stream: _queueStateStream,
                  builder: (context, snapshot) {
                    final mediaItem = snapshot.data?.mediaItem;
                    return Positioned(
                        left: 6,
                        right: 6,
                        bottom: 14,
                        child: BottomNavigationAudioPlayer(
                          isElevated: true,
                          isVisible: mediaItem != null,
                          displayTitle: mediaItem?.displayTitle ?? "",
                          displaySubtitle: mediaItem?.displaySubtitle ?? "",
                          displayThumbnailUrl: mediaItem?.artUri.toString() ?? "",
                          audioHandler: _audioHandler,
                        ));
                  },
                ),
              ],
            )));
  }
  @override
  void dispose() {
    // Clean up resources, subscriptions, controllers, etc.
    super.dispose();
    _sub.cancel();
  }
}
