import 'package:flutter_test/flutter_test.dart';
import 'package:radio_crestin/services/notification_permission_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the service asked the platform to do.
class _FakeMessaging {
  _FakeMessaging({this.authorized = false, this.grantOnRequest = true});

  bool authorized;
  bool grantOnRequest;
  int authorizationChecks = 0;
  int permissionRequests = 0;
  int tokenRegistrations = 0;

  Future<bool> isAuthorized() async {
    authorizationChecks++;
    return authorized;
  }

  Future<bool> requestPermission() async {
    permissionRequests++;
    authorized = grantOnRequest;
    return grantOnRequest;
  }

  Future<void> registerToken() async {
    tokenRegistrations++;
  }
}

void main() {
  group('NotificationPermissionService', () {
    late _FakeMessaging messaging;

    Future<NotificationPermissionService> build({
      Map<String, Object> initial = const {},
      bool authorized = false,
      bool grantOnRequest = true,
      bool tokenNeedsPermission = true,
    }) async {
      SharedPreferences.setMockInitialValues(initial);
      final prefs = await SharedPreferences.getInstance();
      messaging = _FakeMessaging(
        authorized: authorized,
        grantOnRequest: grantOnRequest,
      );
      return NotificationPermissionService(
        prefs: prefs,
        isAuthorized: messaging.isAuthorized,
        requestPermission: messaging.requestPermission,
        registerToken: messaging.registerToken,
        tokenNeedsPermission: tokenNeedsPermission,
      );
    }

    test('startup never asks for permission', () async {
      final service = await build();

      await service.initialize();

      expect(messaging.permissionRequests, 0);
      expect(service.hasPrompted, isFalse);
      expect(service.playCount, 0);
    });

    test('first play does not prompt', () async {
      final service = await build();
      await service.initialize();

      await service.onStationPlayed();

      expect(messaging.permissionRequests, 0);
      expect(service.playCount, 1);
      expect(service.hasPrompted, isFalse);
    });

    test('second play prompts exactly once', () async {
      final service = await build();
      await service.initialize();

      await service.onStationPlayed();
      await service.onStationPlayed();
      await service.onStationPlayed();
      await service.onStationPlayed();

      expect(messaging.permissionRequests, 1);
      expect(service.hasPrompted, isTrue);
      expect(messaging.tokenRegistrations, 1);
    });

    test('a denied prompt is never repeated automatically', () async {
      final service = await build(grantOnRequest: false);
      await service.initialize();

      await service.onStationPlayed();
      await service.onStationPlayed();
      await service.onStationPlayed();

      expect(messaging.permissionRequests, 1);
      expect(messaging.tokenRegistrations, 0);
      expect(service.hasPrompted, isTrue);
    });

    test('the counter survives a restart', () async {
      final first = await build();
      await first.onStationPlayed();
      expect(first.playCount, 1);

      final second = await build(initial: {
        'notification_prompt_play_count': 1,
      });
      await second.onStationPlayed();

      expect(second.playCount, 2);
      expect(messaging.permissionRequests, 1);
    });

    test('already-granted users are never prompted and keep FCM working',
        () async {
      final service = await build(authorized: true);

      await service.initialize();
      await service.onStationPlayed();
      await service.onStationPlayed();

      expect(messaging.permissionRequests, 0);
      expect(messaging.tokenRegistrations, 1);
      expect(service.hasPrompted, isTrue);
      expect(service.playCount, 0);
    });

    test('platforms whose token needs no permission register at startup',
        () async {
      final service = await build(tokenNeedsPermission: false);

      await service.initialize();

      expect(messaging.tokenRegistrations, 1);
      expect(messaging.permissionRequests, 0);
      expect(service.hasPrompted, isFalse);
    });

    test('a custom threshold shifts the prompt', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      messaging = _FakeMessaging();
      final service = NotificationPermissionService(
        prefs: prefs,
        isAuthorized: messaging.isAuthorized,
        requestPermission: messaging.requestPermission,
        registerToken: messaging.registerToken,
        playsBeforePrompt: 3,
      );

      await service.onStationPlayed();
      await service.onStationPlayed();
      expect(messaging.permissionRequests, 0);

      await service.onStationPlayed();
      expect(messaging.permissionRequests, 1);
    });

    test('plugin failures never escape', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = NotificationPermissionService(
        prefs: prefs,
        isAuthorized: () async => throw StateError('no play services'),
        requestPermission: () async => throw StateError('no APNS token'),
        registerToken: () async => throw StateError('SERVICE_NOT_AVAILABLE'),
      );

      await service.initialize();
      await service.onStationPlayed();
      await service.onStationPlayed();

      expect(service.hasPrompted, isTrue);
    });
  });
}
