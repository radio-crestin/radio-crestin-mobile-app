import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' as ndef;
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/main.dart';
import 'package:rxdart/rxdart.dart';
import 'package:url_launcher/url_launcher.dart';

import 'HomePage.dart';

class WriteNfcTagPage extends StatefulWidget {
  @override
  _WriteNfcTagPageState createState() => _WriteNfcTagPageState();
}

class _WriteNfcTagPageState extends State<WriteNfcTagPage> {
  String? selectedOption;
  late var availability = false;
  late ScaffoldMessengerState scaffoldMessenger;
  List<ndef.NDEFRecord> _records = [];
  final AppAudioHandler _audioHandler = getIt<AppAudioHandler>();

  _WriteNfcTagPageState() {
    FlutterNfcKit.nfcAvailability.then((v) {
      setState(() {
        availability = (v == NFCAvailability.available);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    scaffoldMessenger = ScaffoldMessenger.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inscripționare tag NFC'),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18.0, horizontal: 20.0),
        child: Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                child: Text.rich(
                  TextSpan(
                    text: 'Pentru a programa pornirea unei stații radio la atingerea unui tag NFC, vă recomandam să achiziționați tag-ul ',
                    children: [
                      TextSpan(
                        text: 'NFC 13.56 MHZ',
                        style: const TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () {
                            launchUrl(Uri.parse('https://cleste.ro/nfc-sticker-de-1356mhz-ntag213.html'),
                                mode: LaunchMode.externalApplication);
                          },
                      ),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
              StreamBuilder<HomePageState>(
                stream: Rx.combineLatest2<List<MediaItem>, MediaItem?, HomePageState>(
                  _audioHandler.stationsMediaItems,
                  _audioHandler.mediaItem,
                      (stationsMediaItems, mediaItem) => HomePageState(stationsMediaItems, mediaItem, true),
                ),
                builder: (context, snapshot) {
                  final mediaItems = snapshot.data?.stationsMediaItems ?? [];
                  return DropdownButton<String>(
                    value: selectedOption,
                    items: mediaItems.map((e) {
                      return DropdownMenuItem<String>(
                        value: e.extras?['station_slug'],
                        child: Text(e.title, style: const TextStyle(color: Colors.black)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        selectedOption = value!;
                        _records = [
                          // ndef.UriRecord.fromString("android-app://com.radiocrestin.radio_crestin/https/www.radiocrestin.ro/radio/${value}/?nfc_tag=true"),
                          ndef.UriRecord.fromString("https://share.radiocrestin.ro/$value?ref=nfc"),
                        ];
                      });
                    },
                    hint: const Text('Selectează o stație pentru inscripționare', style: TextStyle(color: Colors.black)),
                  );
                },
              ),

              const SizedBox(height: 20),
              if (!availability) const Text(
                'Telefonul dumneavoastră nu suportă scrierea tag-urilor NFC.',
                style: TextStyle(fontSize: 16),
              ),
              if (availability && _records.isNotEmpty) (
                  ElevatedButton(
                    onPressed: () {
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(
                          content: Text("Va rugam sa apropriati tag-ul NFC."),
                          duration: Duration(seconds: 3),
                        ),
                      );
                      FlutterNfcKit.poll().then((value) async {
                        developer.log("Scanned NFC tag: ${value.toJson()}");
                        await FlutterNfcKit.writeNDEFRecords(_records);
                        await FlutterNfcKit.finish();
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        scaffoldMessenger.showSnackBar(
                          const SnackBar(
                            content: Text("Tag-ul NFC a fost inscriptionata."),
                            duration: Duration(seconds: 3),
                          ),
                        );
                      });
                    },
                    child: const Text('Incepe inscriptionarea'),
                  )
              ),
            ],
          ),
        )
      ),
    );
  }

  Future<bool> writeNfcTag() async {
    // Use flutter_nfc_kit or any other NFC writing logic here
    // For the sake of example, we're simulating a successful write
    return true;
  }
}
