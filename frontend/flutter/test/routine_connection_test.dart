import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:heatguard_mobile/services/heatguard_api.dart';
import 'package:heatguard_mobile/services/routine_push_service.dart';
import 'package:heatguard_mobile/services/routines_controller.dart';

class ConnectionApi extends HeatGuardApi {
  int registrations = 0;
  bool offline = false;
  @override
  Future<Map<String, dynamic>> accountSession(String baseUrl) async => {};
  @override
  Future<Map<String, dynamic>> fetchRoutines(String baseUrl) async => {
    'routines': [],
    'push_available': true,
  };
  @override
  Future<Map<String, dynamic>> fetchNotifications(String baseUrl) async => {
    'notifications': [],
    'unread_count': 0,
  };
  @override
  Future<Map<String, dynamic>> registerPushDevice(
    String baseUrl,
    String token,
  ) async {
    registrations++;
    if (offline) throw StateError('Server unavailable.');
    return {};
  }
}

class ConnectionPush extends RoutinePushService {
  int enables = 0, refreshes = 0, permissionRequests = 0;
  Completer<void>? gate;
  @override
  bool get isSupported => true;
  @override
  Future<void> enable({
    required int accountId,
    required Future<void> Function(String) onToken,
    required VoidCallback onMessage,
    required void Function(int?) onOpen,
    bool requestPermission = true,
  }) async {
    enables++;
    if (requestPermission) permissionRequests++;
    await gate?.future;
    await onToken('test-device');
  }

  @override
  Future<void> refresh({required Future<void> Function(String) onToken}) async {
    refreshes++;
    await onToken('test-device');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const baseUrl = 'http://example.test';
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          'routine_push:$baseUrl:1': true,
        });
  });

  test(
    'restore is quiet and repeated resumes reuse the registration',
    () async {
      final api = ConnectionApi();
      final push = ConnectionPush()..gate = Completer<void>();
      var now = DateTime(2026, 10, 22);
      final controller = RoutinesController(
        api: api,
        baseUrl: baseUrl,
        accountId: 1,
        push: push,
        now: () => now,
      );
      addTearDown(controller.dispose);
      final visibleBusyStates = <bool>[];
      controller.addListener(() => visibleBusyStates.add(controller.busy));
      final initialization = controller.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(push.enables, 1);
      expect(controller.pushEnabled, isTrue);
      expect(controller.busy, isFalse);
      await controller.resume(); // Do not start overlapping registration.
      expect(push.enables, 1);
      push.gate!.complete();
      await initialization;
      await controller.resume();
      await controller.resume();
      expect(api.registrations, 1);
      expect(push.permissionRequests, 0);
      expect(visibleBusyStates, everyElement(isFalse));
      now = now.add(const Duration(minutes: 6));
      await controller.resume();
      expect(push.enables, 1);
      expect(push.refreshes, 1);
      expect(api.registrations, 2);
      expect(push.permissionRequests, 0);
    },
  );

  test(
    'failed background registration keeps opt-in and retries without a prompt',
    () async {
      final api = ConnectionApi()..offline = true;
      final push = ConnectionPush();
      var now = DateTime(2026, 10, 22);
      final controller = RoutinesController(
        api: api,
        baseUrl: baseUrl,
        accountId: 1,
        push: push,
        now: () => now,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.pushEnabled, isTrue);
      expect(controller.busy, isFalse);
      expect(controller.pushError, isNotNull);
      await controller.resume();
      expect(api.registrations, 1);
      api.offline = false;
      now = now.add(const Duration(seconds: 31));
      await controller.resume();
      expect(api.registrations, 2);
      expect(controller.pushError, isNull);
      expect(push.permissionRequests, 0);
    },
  );

  test('explicit enable shows progress and requests permission once', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({});
    final api = ConnectionApi();
    final push = ConnectionPush()..gate = Completer<void>();
    final controller = RoutinesController(
      api: api,
      baseUrl: baseUrl,
      accountId: 1,
      push: push,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final enable = controller.enablePush();
    expect(controller.busy, isTrue);
    expect(push.permissionRequests, 1);
    push.gate!.complete();
    await enable;
    expect(controller.pushEnabled, isTrue);
    expect(controller.busy, isFalse);
    await controller.resume();
    expect(push.enables, 1);
  });
}
