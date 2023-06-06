

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/components/BottomNavigationAudioPlayer.dart';
import 'package:radio_crestin/pages/SettingsPage.dart';
import 'package:radio_crestin/components/StationsList.dart';
import 'package:url_launcher/url_launcher.dart';

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
        if(_isVisible) {
          setState(() {
            _isVisible = false;
          });
        }
      }
      if (_hideButtonController.position.userScrollDirection ==
          ScrollDirection.forward) {
        if(!_isVisible) {
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
    print("appPlaybackState?.processingState: ${audioHandler.appPlaybackState?.processingState}");
    return Scaffold(
      appBar:  AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.grey[500],
        toolbarHeight: 60,
        leading: const Center(
          child: Image(image: AssetImage('assets/launcher_icon/ic_launcher.png'), width: 30, height: 30)
        ),
        title: Container(
          child: Text('Radio Crestin'),
          transform: Matrix4.translationValues(-16, 0, 0.0),
        ),
          titleTextStyle: const TextStyle(
            color: Colors.black,
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
            icon: const Icon(Icons.email),
            tooltip: 'Contacteaza-ne',
            onPressed: () {
              // https://pub.dev/packages/url_launcher
              // TODO: we might need to add some additional details for iOS
              launchUrl(Uri.parse("https://wa.me/40773994595?text=Buna%20ziua"),
                  mode: LaunchMode.externalApplication);
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
      body: StationsList(
        stations: audioHandler.stations,
        onStationSelected: (stationIdx) {
          audioHandler.setStationIdx(stationIdx);
          audioHandler.play();
        },
        hideButtonController: _hideButtonController,
      ),
      bottomNavigationBar: BottomNavigationAudioPlayer(
        isElevated: true,
        isVisible: audioHandler.stationIdx != null,
        stationIdx: audioHandler.stationIdx ?? 0,
        displayTitle: audioHandler.metadata.displayTitle ?? "",
        displaySubtitle: audioHandler.metadata.displaySubtitle ?? "",
        displayThumbnailUrl: audioHandler.metadata.artUri.toString() ?? "",
        appPlaybackState: audioHandler.appPlaybackState,
        playerStarted: audioHandler.started,
        onPlay: audioHandler.onPlayButtonPressed,
        onPause: audioHandler.onPauseButtonPressed,
        onPreviousStation: audioHandler.onPreviousStationButtonPressed,
        onNextStation: audioHandler.onNextStationButtonPressed,
      ),
    );
  }
}