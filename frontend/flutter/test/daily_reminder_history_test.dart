import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:heatguard_mobile/models/heatguard_models.dart';
import 'package:heatguard_mobile/services/daily_notification_service.dart';
import 'package:heatguard_mobile/services/daily_reminder_history.dart';
import 'package:heatguard_mobile/services/heatguard_api.dart';
import 'package:heatguard_mobile/services/routines_controller.dart';

class _InboxApi extends HeatGuardApi {
  bool offline = false;
  int sessionChecks = 0, readRequests = 0;
  @override
  Future<Map<String, dynamic>> fetchRoutines(String baseUrl) async {
    if (offline) throw const HeatGuardApiException('The server is offline.');
    return {'routines': []};
  }

  @override
  Future<Map<String, dynamic>> fetchNotifications(String baseUrl) async => {
    'notifications': [
      {
        'id': 7,
        'title': 'School reminder',
        'body': 'Your routine advice.',
        'created_at': '2026-10-22T01:00:00Z',
        'read': false,
      },
    ],
    'unread_count': 1,
  };

  @override
  Future<Map<String, dynamic>> accountSession(String baseUrl) async {
    sessionChecks++;
    return {};
  }

  @override
  Future<Map<String, dynamic>> readNotification(
    String baseUrl, {
    int? id,
  }) async {
    readRequests++;
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late DailyReminderHistory history;
  DailyReminderHistory store({
    int account = 1,
    String server = 'http://test',
  }) =>
      DailyReminderHistory(baseUrl: server, accountId: account, now: () => now);

  Future<void> schedule({String name = 'Manila', int minute = 0}) =>
      history.schedule(
        firstDelivery: DateTime.utc(2026, 10, 22, 2, minute),
        timezone: 'Asia/Manila',
        hour: 10,
        minute: minute,
        title: 'HeatGuard · $name',
        body: 'Weather for $name.',
      );

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({});
    now = DateTime.utc(2026, 10, 22, 1, 59);
    history = store();
  });

  test(
    'future reminders stay hidden and closed-app occurrences survive restart',
    () async {
      await schedule();
      expect(await history.inbox(), isEmpty);
      now = DateTime.utc(2026, 10, 24, 2);
      final notices = await store().inbox();
      expect(notices, hasLength(3));
      expect(notices.map((n) => n.id).toSet(), hasLength(3));
      expect(notices.every((n) => n.isDailyDeviceReminder && !n.read), isTrue);
      expect(notices.first.scheduledFor, DateTime.utc(2026, 10, 24, 2));
      expect(await store().inbox(), hasLength(3));
      await store().markRead(id: notices.first.id);
      expect((await store().inbox()).first.read, isTrue);
      await store().markRead();
      expect((await store().inbox()).every((n) => n.read), isTrue);
      now = DateTime.utc(2026, 10, 25, 2);
      final nextDay = await store().inbox();
      expect(nextDay, hasLength(4));
      expect(nextDay.first.read, isFalse);
    },
  );

  test(
    'changing location and time preserves earlier reminders on the same day',
    () async {
      await schedule(name: 'Kalayaan');
      now = DateTime.utc(2026, 10, 22, 2, 0, 10);
      await schedule(name: 'Manila', minute: 1);
      expect(await history.inbox(), hasLength(1));
      now = DateTime.utc(2026, 10, 22, 2, 1);
      final notices = await history.inbox();
      expect(notices, hasLength(2));
      expect(notices.first.title, contains('Manila'));
      expect(notices.last.title, contains('Kalayaan'));
      expect(notices.first.body, contains('Manila'));
    },
  );

  test('pausing keeps past entries and cancels future history', () async {
    await schedule();
    now = DateTime.utc(2026, 10, 22, 2);
    await history.cancel();
    now = DateTime.utc(2026, 10, 24, 2);
    expect(await history.inbox(), hasLength(1));
  });

  test('pausing before delivery does not create a history entry', () async {
    await schedule();
    await history.cancel();
    now = DateTime.utc(2026, 10, 24, 2);
    expect(await history.inbox(), isEmpty);
  });

  test(
    'accounts and servers cannot read each other’s device history',
    () async {
      await schedule();
      now = DateTime.utc(2026, 10, 22, 2);
      expect(await history.inbox(), hasLength(1));
      expect(await store(account: 2).inbox(), isEmpty);
      expect(await store(server: 'http://other').inbox(), isEmpty);
      expect(DailyReminderHistory.matchesPayload(history.payload, 2), isFalse);
    },
  );

  test('long absences are bounded and calendar schedules handle DST', () async {
    await history.schedule(
      firstDelivery: DateTime.utc(2024, 3, 9, 13),
      timezone: 'America/New_York',
      hour: 8,
      minute: 0,
      title: 'Daily update',
      body: 'Weather guidance.',
    );
    now = DateTime.utc(2024, 3, 10, 12);
    final dst = await history.inbox();
    expect(dst.map((n) => n.scheduledFor), [
      DateTime.utc(2024, 3, 10, 12),
      DateTime.utc(2024, 3, 9, 13),
    ]);
    now = DateTime.utc(2026, 10, 22, 12);
    expect(await history.inbox(), hasLength(100));
  });

  test(
    'controller merges daily and server notices and reads local entries offline',
    () async {
      await schedule();
      now = DateTime.utc(2026, 10, 22, 2);
      final api = _InboxApi();
      final controller = RoutinesController(
        api: api,
        baseUrl: 'http://test',
        accountId: 1,
        dailyHistory: history,
      );
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await controller.reload();
      expect(controller.notices.map((n) => n.title), [
        'HeatGuard · Manila',
        'School reminder',
      ]);
      expect(controller.unread, 2);
      api.offline = true;
      await controller.reload();
      expect(controller.error, 'The server is offline.');
      expect(controller.notices, hasLength(2));
      await controller.markRead(id: controller.notices.first.id);
      expect(controller.notices.first.read, isTrue);
      expect(controller.unread, 1);
      expect(api.sessionChecks, 0);
      expect(api.readRequests, 0);
      final restored = RoutinesController(
        api: api,
        baseUrl: 'http://test',
        accountId: 1,
        dailyHistory: store(),
      );
      addTearDown(restored.dispose);
      await restored.reload();
      expect(restored.notices.single.read, isTrue);
    },
  );

  test(
    'native daily scheduling records history and preserves it when paused',
    () async {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_timezone'),
        (_) async => 'Asia/Manila',
      );
      final nativeSchedules = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (call) async {
          if (call.method == 'zonedSchedule') {
            nativeSchedules.add(call.arguments as Map);
          }
          return true;
        },
      );
      final service = DailyNotificationService(now: () => now)
        ..history = history;
      final dashboard = HeatDashboard.fromJson({
        'location': {'id': 3, 'name': 'Manila'},
        'data_status': 'ok',
        'current': {
          'heat_index_c': 30,
          'risk': {'label': 'Caution'},
        },
        'recommendations': ['Check local conditions.'],
      });
      await service.scheduleDaily(dashboard, hour: 10, minute: 0);
      expect(nativeSchedules.single['payload'], history.payload);
      expect(await history.inbox(), isEmpty);
      now = DateTime.utc(2026, 10, 22, 2);
      final notice = (await history.inbox()).single;
      expect(notice.title, nativeSchedules.single['title']);
      expect(notice.body, nativeSchedules.single['body']);
      await service.cancelDaily();
      now = DateTime.utc(2026, 10, 24, 2);
      expect(await history.inbox(), hasLength(1));
    },
  );
}
