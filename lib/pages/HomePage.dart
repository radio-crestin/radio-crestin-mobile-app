import 'package:audio_service/audio_service.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/BottomNavigationAudioPlayer.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:radio_crestin/components/QueueList.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:developer' as developer;

import 'package:upgrader/upgrader.dart';

import '../main.dart';

final remoteConfig = FirebaseRemoteConfig.instance;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late ScrollController _hideButtonController;

  var _isVisible;
  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();

  _HomePageState();

  /// A stream reporting the combined state of the current queue and the current
  /// media item within that queue.
  Stream<QueueState> get _queueStateStream =>
      Rx.combineLatest2<List<MediaItem>, MediaItem?, QueueState>(
          _audioHandler.queue,
          _audioHandler.mediaItem,
              (queue, mediaItem) => QueueState(queue, mediaItem));

  @override
  initState() {
    super.initState();
    _isVisible = true;
    _hideButtonController = new ScrollController();
    _hideButtonController.addListener(() {
      if (_hideButtonController.position.userScrollDirection ==
          ScrollDirection.reverse) {
        if (_isVisible) {
          setState(() {
            _isVisible = false;
          });
        }
      }
      if (_hideButtonController.position.userScrollDirection ==
          ScrollDirection.forward) {
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
                      image: AssetImage('assets/icons/ic_foreground.png'),
                      width: 30,
                      height: 30)),
              title: Container(
                child: Text('Radio Crestin'),
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
                IconButton(
                  icon: const Icon(Icons.campaign),
                  tooltip: 'Trimite aplicatia prietenilor tai',
                  onPressed: () {
                    // TODO: adapteaza mesajul in functie de dispozitiv
                    Share.share(remoteConfig.getString("share_app_message"));
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
                    final queue = snapshot.data?.queue ?? [];
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
                          // stationIdx: _audioHandler.stationIdx ?? 0,
                          stationIdx: 0,
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
}
