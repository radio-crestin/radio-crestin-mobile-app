import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  group('NetworkService - connectivity logic', () {
    // Test the pure connectivity determination logic from _updateFromResults
    // without needing the connectivity_plus platform channel.

    group('offline detection', () {
      bool isOffline(List<String> results) {
        final mobile = results.contains('mobile');
        final wifi = results.contains('wifi');
        final ethernet = results.contains('ethernet');
        final none = results.contains('none');
        return results.isEmpty || (none && !mobile && !wifi && !ethernet);
      }

      test('empty results means offline', () {
        expect(isOffline([]), true);
      });

      test('only none means offline', () {
        expect(isOffline(['none']), true);
      });

      test('wifi means online', () {
        expect(isOffline(['wifi']), false);
      });

      test('mobile means online', () {
        expect(isOffline(['mobile']), false);
      });

      test('ethernet means online', () {
        expect(isOffline(['ethernet']), false);
      });

      test('none with wifi means online', () {
        expect(isOffline(['none', 'wifi']), false);
      });
    });

    group('mobile data detection', () {
      bool isOnMobileData(List<String> results) {
        final mobile = results.contains('mobile');
        final wifi = results.contains('wifi');
        final ethernet = results.contains('ethernet');
        return mobile && !wifi && !ethernet;
      }

      test('mobile only means on mobile data', () {
        expect(isOnMobileData(['mobile']), true);
      });

      test('mobile with wifi means not on mobile data', () {
        expect(isOnMobileData(['mobile', 'wifi']), false);
      });

      test('wifi only means not on mobile data', () {
        expect(isOnMobileData(['wifi']), false);
      });

      test('mobile with ethernet means not on mobile data', () {
        expect(isOnMobileData(['mobile', 'ethernet']), false);
      });

      test('no results means not on mobile data', () {
        expect(isOnMobileData([]), false);
      });
    });

    group('BehaviorSubject state tracking', () {
      test('isOffline subject emits changes', () async {
        final isOffline = BehaviorSubject.seeded(false);
        final emissions = <bool>[];

        isOffline.listen((v) => emissions.add(v));

        isOffline.add(true);
        isOffline.add(false);
        isOffline.add(true);

        await Future.delayed(const Duration(milliseconds: 50));

        expect(emissions, [false, true, false, true]);

        isOffline.close();
      });

      test('isOnMobileData subject tracks state', () async {
        final isOnMobileData = BehaviorSubject.seeded(false);

        isOnMobileData.add(true);
        expect(isOnMobileData.value, true);

        isOnMobileData.add(false);
        expect(isOnMobileData.value, false);

        isOnMobileData.close();
      });
    });
  });
}
