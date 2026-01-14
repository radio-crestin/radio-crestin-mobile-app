import 'dart:developer' as developer;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:radio_crestin/types/Station.dart';
import 'package:radio_crestin/utils.dart';

FirebaseAnalytics analytics = FirebaseAnalytics.instance;

class AppTracking {
  static trackPlayStation(Station station, {GraphQLClient? graphQLClient}) async {
    Utils.incrementActionsMade(
      graphQLClient: graphQLClient,
      currentStationName: station.title,
      currentStationSlug: station.slug,
    );
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

  static trackListenStation(Station station, String currentStreamUrl) async {
    developer.log("trackListenStation $currentStreamUrl");
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
  }

  static trackStopStation(Station station) async {
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
}
