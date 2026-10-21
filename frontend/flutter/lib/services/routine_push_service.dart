import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> routineBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Notification payloads are displayed by Android; the server owns inbox history.
}

class RoutinePushService {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get isSupported => supported;
  static const _timeout = Duration(seconds: 15);
  static const channel = AndroidNotificationChannel(
    'heatguard_routines',
    'Routine reminders',
    description: 'Personal weather reminders before your activities',
    importance: Importance.high,
  );
  final _notifications = FlutterLocalNotificationsPlugin();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _closed = false;
  bool _launchHandled = false;
  String? token;

  Future<void> enable({
    required int accountId,
    required Future<void> Function(String) onToken,
    required VoidCallback onMessage,
    required void Function(int?) onOpen,
    bool requestPermission = true,
  }) async {
    if (!supported) {
      throw StateError('Push notifications are available in the Android app.');
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp().timeout(_timeout);
    }
    if (_closed) return;
    await _notifications
        .initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('ic_stat_heatguard'),
          ),
          onDidReceiveNotificationResponse: (response) {
            final id = int.tryParse(response.payload ?? '');
            if (id != null && !_closed) onOpen(id);
          },
        )
        .timeout(_timeout);
    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel)
        .timeout(_timeout);
    FirebaseMessaging.onBackgroundMessage(routineBackgroundMessage);
    final messaging = FirebaseMessaging.instance;
    final permission = requestPermission
        ? await messaging.requestPermission(
            alert: true,
            badge: true,
            sound: true,
          )
        : await messaging.getNotificationSettings().timeout(_timeout);
    if (permission.authorizationStatus != AuthorizationStatus.authorized &&
        permission.authorizationStatus != AuthorizationStatus.provisional) {
      throw StateError(
        'Allow HeatGuard notifications in your phone settings to receive reminders.',
      );
    }
    if (_closed) return;
    await messaging.setAutoInitEnabled(true).timeout(_timeout);
    final nextToken = await messaging.getToken().timeout(_timeout);
    if (_closed) return;
    if (nextToken == null) {
      throw StateError(
        'Your phone could not register for notifications. Try again.',
      );
    }
    token = nextToken;
    await _cancelStreams();
    _subscriptions.add(
      messaging.onTokenRefresh.listen((value) async {
        if (_closed) return;
        token = value;
        try {
          await onToken(value);
        } catch (_) {
          /* Retried on app resume. */
        }
      }),
    );
    _subscriptions.add(
      FirebaseMessaging.onMessage.listen((message) async {
        if (_closed || message.data['account_id'] != '$accountId') return;
        onMessage();
        final notice = message.notification;
        if (notice == null) return;
        final id = int.tryParse(message.data['notification_id'] ?? '') ?? 0;
        try {
          await _notifications.show(
            100000 + id % 1000000000,
            notice.title,
            notice.body,
            NotificationDetails(
              android: AndroidNotificationDetails(
                channel.id,
                channel.name,
                channelDescription: channel.description,
                importance: Importance.high,
                priority: Priority.high,
                icon: 'ic_stat_heatguard',
                tag: 'heatguard-routine-$id',
              ),
            ),
            payload: message.data['notification_id'],
          );
        } catch (_) {
          // The persistent inbox remains available if Android hides a banner.
        }
      }),
    );
    _subscriptions.add(
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        if (!_closed && message.data['account_id'] == '$accountId') {
          onOpen(int.tryParse(message.data['notification_id'] ?? ''));
        }
      }),
    );
    await onToken(nextToken);
    if (_closed) return;
    final initial = await messaging.getInitialMessage().timeout(_timeout);
    if (!_closed && initial?.data['account_id'] == '$accountId') {
      onOpen(int.tryParse(initial?.data['notification_id'] ?? ''));
    }
    if (!_launchHandled) {
      _launchHandled = true;
      final launch = await _notifications
          .getNotificationAppLaunchDetails()
          .timeout(_timeout);
      final localId = int.tryParse(launch?.notificationResponse?.payload ?? '');
      if (!_closed &&
          launch?.didNotificationLaunchApp == true &&
          localId != null) {
        onOpen(localId);
      }
    }
  }

  Future<void> refresh({required Future<void> Function(String) onToken}) async {
    if (_closed || !supported || Firebase.apps.isEmpty) return;
    final messaging = FirebaseMessaging.instance;
    final permission = await messaging.getNotificationSettings().timeout(
      _timeout,
    );
    if (permission.authorizationStatus != AuthorizationStatus.authorized &&
        permission.authorizationStatus != AuthorizationStatus.provisional) {
      throw StateError(
        'Allow HeatGuard notifications in your phone settings to receive reminders.',
      );
    }
    final nextToken = await messaging.getToken().timeout(_timeout);
    if (_closed) return;
    if (nextToken == null) {
      throw StateError(
        'Your phone could not register for notifications. Try again.',
      );
    }
    token = nextToken;
    await onToken(nextToken);
  }

  Future<void> _cancelStreams() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> dispose() async {
    _closed = true;
    await _cancelStreams();
  }

  Future<void> pause() async {
    await _cancelStreams();
    token = null;
  }

  static Future<void> clearAccount({bool cancelNotifications = true}) async {
    if (!supported || Firebase.apps.isEmpty) return;
    try {
      await FirebaseMessaging.instance.deleteToken().timeout(
        const Duration(seconds: 5),
      );
      await FirebaseMessaging.instance.setAutoInitEnabled(false);
      if (cancelNotifications) {
        await FlutterLocalNotificationsPlugin().cancelAll();
      }
    } catch (_) {
      /* Server-side session deletion also unregisters the device. */
    }
  }
}
