import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/BottomNavigationAudioPlayer.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:developer' as developer;

import 'package:upgrader/upgrader.dart';

final remoteConfig = FirebaseRemoteConfig.instance;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late ScrollController _hideButtonController;

  var _isVisible;

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
    final audioHandler = context.watch<AppAudioHandler>();
    developer.log(
        "appPlaybackState?.processingState: ${audioHandler.appPlaybackState?.processingState}");
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
                StationsList(
                  stations: audioHandler.stations,
                  selectedStationIdx: audioHandler.stationIdx ?? 0,
                  onStationSelected: (stationIdx) {
                    audioHandler.setStationIdx(stationIdx);
                    audioHandler.play();
                  },
                  hideButtonController: _hideButtonController,
                ),
                Positioned(
                    left: 6,
                    right: 6,
                    bottom: 14,
                    child: BottomNavigationAudioPlayer(
                      isElevated: true,
                      isVisible: audioHandler.stationIdx != null,
                      stationIdx: audioHandler.stationIdx ?? 0,
                      displayTitle: audioHandler.metadata.displayTitle ?? "",
                      displaySubtitle:
                          audioHandler.metadata.displaySubtitle ?? "",
                      displayThumbnailUrl:
                          audioHandler.metadata.artUri.toString() ?? "",
                      audioHandler: audioHandler,
                    ))
              ],
            )));
  }
}
