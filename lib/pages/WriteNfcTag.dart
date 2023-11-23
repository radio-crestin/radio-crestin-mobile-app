import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:ndef/ndef.dart' as ndef;

class WriteNfcTagPage extends StatefulWidget {
  @override
  _WriteNfcTagPageState createState() => _WriteNfcTagPageState();
}

class _WriteNfcTagPageState extends State<WriteNfcTagPage> {
  String? selectedOption;
  late var availability = false;
  late ScaffoldMessengerState scaffoldMessenger;
  List<ndef.NDEFRecord> _records = [];

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DropdownButton<String>(
              value: selectedOption,
              items: [
                DropdownMenuItem<String>(
                  value: 'rve-timisoara',
                  child: Text('RVE Timisoara', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem<String>(
                  value: 'aripi-spre-cer',
                  child: Text('Aripi Spre Cer', style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem<String>(
                  value: 'Option 3',
                  child: Text('Option 3', style: TextStyle(color: Colors.black)),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  selectedOption = value!;
                  _records = [
                    // ndef.UriRecord.fromString("android-app://com.radiocrestin.radio_crestin/https/www.radiocrestin.ro/radio/${value}/?nfc_tag=true"),
                    ndef.UriRecord.fromString("https://www.radiocrestin.ro/${value}/?nfc_tag=true"),
                  ];
                });
              },
              hint: Text('Vă rugam să selectați o stație', style: TextStyle(color: Colors.black)),
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
