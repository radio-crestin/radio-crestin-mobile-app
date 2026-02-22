import 'dart:developer' as developer;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils.dart';

FirebaseAnalytics analytics = FirebaseAnalytics.instance;

class AppTracking {
  // All tracking methods are fire-and-forget: no awaiting Firebase calls
  // to avoid competing with UI frame rendering on the main thread.

  static void trackPlayStation(Station station, {GraphQLClient? graphQLClient}) {
    Utils.incrementActionsMade(
      graphQLClient: graphQLClient,
      currentStationName: station.title,
    );
    developer.log("trackPlayStation");
    FirebaseAnalytics.instance.logEvent(name: "listen_radio_start", parameters: {
      "station_id": station.id,
      "station_name": station.title,
    });
    FirebaseAnalytics.instance.logPurchase(
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
    FirebaseAnalytics.instance.logEvent(
      name: 'screen_view',
      parameters: {
        'station_id': station.id,
        'station_name': station.title,
        'firebase_screen': station.title,
        'firebase_screen_class': "RadioStation",
      },
    );
  }

  static void trackListenStation(Station station, String currentStreamUrl) {
    developer.log("trackListenStation $currentStreamUrl");
    FirebaseAnalytics.instance.logEvent(name: "listen_radio_listening", parameters: {
      "station_id": station.id,
      "station_name": station.title,
    });
    FirebaseAnalytics.instance.logPurchase(
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
  }

  static void trackStopStation(Station station) {
    developer.log("trackStopStation");
    FirebaseAnalytics.instance.logEvent(name: "listen_radio_stop", parameters: {
      "station_id": station.id,
      "station_name": station.title,
    });
    FirebaseAnalytics.instance.logEvent(
      name: 'screen_view',
      parameters: {
        'station_id': station.id,
        'station_name': station.title,
        'firebase_screen': "StopRadio",
        'firebase_screen_class': "RadioStation",
      },
    );
  }
}
