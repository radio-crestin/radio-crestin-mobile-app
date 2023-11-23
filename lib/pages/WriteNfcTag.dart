import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' as ndef;
import 'package:radio_crestin/appAudioHandler.dart';
import 'package:radio_crestin/main.dart';
import 'package:rxdart/rxdart.dart';

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
  Stream<QueueState> get _queueStateStream =>
      Rx.combineLatest2<List<MediaItem>, MediaItem?, QueueState>(_audioHandler.stationsMediaItems,
          _audioHandler.mediaItem, (queue, mediaItem) => QueueState(queue, mediaItem));

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
        title: const Text('Inscripționare etichetă NFC'),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18.0, horizontal: 20.0),
        child: Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[

              StreamBuilder<QueueState>(
                stream: _queueStateStream,
                builder: (context, snapshot) {
                  final mediaItems = snapshot.data?.stationsMediaItems ?? [];
                  return DropdownButton<String>(
                    value: selectedOption,
                    items: mediaItems.map((e) {
                      return DropdownMenuItem<String>(
                        value: e.extras?['station_slug'],
                        child: Text(e.title, style: TextStyle(color: Colors.black)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        selectedOption = value!;
                        _records = [
                          // ndef.UriRecord.fromString("android-app://com.radiocrestin.radio_crestin/https/www.radiocrestin.ro/radio/${value}/?nfc_tag=true"),
                          ndef.UriRecord.fromString("https://www.radiocrestin.ro/${value}/?nfc_tag=true"),
                        ];
                      });
                    },
                    hint: Text('Vă rugăm să selectați o stație', style: TextStyle(color: Colors.black)),
                  );
                },
              ),

              SizedBox(height: 20),
              if (!availability) Text(
                'Telefonul dumneavoastră nu suportă scrierea etichetelor NFC.',
                style: TextStyle(fontSize: 16),
              ),
              if (availability && _records.length > 0) (
                  ElevatedButton(
                    onPressed: () {
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(
                          content: Text("Va rugam sa apropriati eticheta NFC."),
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
                            content: Text("Eticheta NFC a fost inscriptionata."),
                            duration: Duration(seconds: 3),
                          ),
                        );
                      });
                    },
                    child: Text('Incepe inscriptionarea'),
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
