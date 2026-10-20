import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/heatguard_models.dart';

class DailyNotificationService {
  DailyNotificationService() : _plugin = FlutterLocalNotificationsPlugin();

  static const int _notificationId = 2317;
  static const String _channelId = 'heatguard_daily';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) {
      _initialized = true;
      return;
    }

    tz_data.initializeTimeZones();
    final zone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(zone.identifier));

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_heatguard'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings);
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    if (!_initialized) await initialize();

    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final alreadyEnabled = await android?.areNotificationsEnabled();
      if (alreadyEnabled == true) return true;
      return await android?.requestNotificationsPermission() ?? false;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return false;
  }

  Future<void> scheduleDaily(
    HeatDashboard dashboard, {
    required int hour,
    required int minute,
  }) async {
    if (kIsWeb) return;
    if (!_initialized) await initialize();
    final now = tz.TZDateTime.now(tz.local);
    var firstDelivery = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!firstDelivery.isAfter(now)) {
      firstDelivery = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day + 1,
        hour,
        minute,
      );
    }

    await _plugin.zonedSchedule(
      _notificationId,
      _titleFor(dashboard),
      _bodyFor(dashboard),
      firstDelivery,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Daily HeatGuard update',
          channelDescription: 'Daily local heat conditions and safety tips',
          icon: 'ic_stat_heatguard',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  Future<void> cancelDaily() async {
    if (kIsWeb) return;
    await _plugin.cancel(_notificationId);
  }

  String _titleFor(HeatDashboard dashboard) =>
      'HeatGuard · ${dashboard.location.name}';

  String _bodyFor(HeatDashboard dashboard) {
    final recommendation = dashboard.recommendations.isEmpty
        ? 'Check HeatGuard for today’s safety guidance.'
        : dashboard.recommendations.first;

    if (dashboard.dataStatus != 'ok' || dashboard.heatIndexC == null) {
      return _limit('Current heat conditions are unknown. $recommendation');
    }

    final heatIndex = dashboard.heatIndexC!.toStringAsFixed(1);
    return _limit(
      'Heat index $heatIndex°C · ${dashboard.riskLabel}. $recommendation',
    );
  }

  String _limit(String value) =>
      value.length > 240 ? '${value.substring(0, 237)}…' : value;
}
