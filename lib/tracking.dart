import 'dart:convert';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:radio_crestin/queries/getStations.graphql.dart';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'globals.dart' as globals;

FirebaseAnalytics analytics = FirebaseAnalytics.instance;

class AppTracking {
  static trackPlayStation(Query$GetStations$stations station) async {
    developer.log("trackPlayStation");
    await FirebaseAnalytics.instance.logEvent(name: "listen_radio_start", parameters: {
      "station_id": station.id,
      "station_name": station.title,
    });
    await FirebaseAnalytics.instance.logPurchase(
      currency: "RON",
      value: 1.0,
      items: [
        AnalyticsEventItem(
          itemCategory: "listen_radio_start",
          index: station.id,
          itemName: station.title,
            quantity: 1,
        ),
      ],
    );
    await FirebaseAnalytics.instance.logEvent(
      name: 'screen_view',
      parameters: {
        'station_id': station.id,
        'station_name': station.title,
        'firebase_screen': station.title,
        'firebase_screen_class': "RadioStation",
      },
    );
  }
  static trackListenStation(Query$GetStations$stations station, String currentStreamUrl) async {
    developer.log("trackListenStation");
    await FirebaseAnalytics.instance.logEvent(name: "listen_radio_listening", parameters: {
      "station_id": station.id,
      "station_name": station.title,
    });
    await FirebaseAnalytics.instance.logPurchase(
      currency: "RON",
      value: 0.5,
      items: [
        AnalyticsEventItem(
          itemCategory: "listen_radio_listening",
          index: station.id,
          itemName: station.title,
          quantity: 1,
        ),
      ],
    );

    await sendListeningEvent(station, currentStreamUrl);

  }
  static trackStopStation(Query$GetStations$stations station) async {
    developer.log("trackStopStation");
    await FirebaseAnalytics.instance.logEvent(name: "listen_radio_stop", parameters: {
      "station_id": station.id,
      "station_name": station.title,
    });
    await FirebaseAnalytics.instance.logEvent(
      name: 'screen_view',
      parameters: {
        'station_id': station.id,
        'station_name': station.title,
        'firebase_screen': "StopRadio",
        'firebase_screen_class': "RadioStation",
      },
    );
  }

  static sendListeningEvent(Query$GetStations$stations station, String currentStreamUrl) async {
    if(currentStreamUrl.contains("/hls/") || currentStreamUrl.contains("proxy.radio-crestin.com")) {
      developer.log("sendListeningEvent");
      var response = await http.post(
          Uri.parse('https://www.radio-crestin.com/api/v1/listen'),
          headers: <String, String>{
            'Content-Type': 'application/json; charset=UTF-8',
          },
          body: jsonEncode({
            "station_id": station.id,
            "info": {
              "mobile_app": true,
              "fcmToken": globals.fcmToken
            }
          })
      );
      developer.log("sendListeningEvent ${response.statusCode} ${response.body}");
    }
  }
}
