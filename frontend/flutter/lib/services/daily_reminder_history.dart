import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/routine_models.dart';

/// A device-local inbox for daily reminders, isolated by server and account.
/// Like the server inbox, an entry means a reminder became due, not that the
/// operating system confirmed displaying its banner.
class DailyReminderHistory {
  DailyReminderHistory({
    required String baseUrl,
    required this.accountId,
    DateTime Function()? now,
  }) : _key =
           'daily_history:${baseUrl.replaceFirst(RegExp(r'/+$'), '')}:$accountId',
       _now = now ?? DateTime.now;

  final int accountId;
  final String _key;
  final DateTime Function() _now;
  final _preferences = SharedPreferencesAsync();
  Future<void> _pending = Future<void>.value();
  static const limit = 100;

  String get payload => 'heatguard-daily:$accountId';

  static bool matchesPayload(String? payload, int accountId) =>
      payload == 'heatguard-daily:$accountId';

  Future<T> _update<T>(T Function(Map<String, dynamic>) change) {
    // The scheduler and inbox share this store. Serialize their read/write cycles.
    final operation = _pending.then((_) async {
      final saved = await _preferences.getString(_key);
      final state = saved == null
          ? <String, dynamic>{'entries': <dynamic>[]}
          : jsonDecode(saved) as Map<String, dynamic>;
      _collectDue(state, _now().toUtc());
      final result = change(state);
      final encoded = jsonEncode(state);
      if (encoded != saved) await _preferences.setString(_key, encoded);
      return result;
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> schedule({
    required DateTime firstDelivery,
    required String timezone,
    required int hour,
    required int minute,
    required String title,
    required String body,
    Map<String, dynamic>? weather,
  }) => _update((state) {
    state['schedule'] = {
      'next_at': firstDelivery.toUtc().toIso8601String(),
      'timezone': timezone,
      'hour': hour,
      'minute': minute,
      'title': title,
      'body': body,
      'weather': weather,
    };
  });

  Future<void> cancel() => _update((state) {
    state.remove('schedule');
  });

  Future<List<RoutineNotice>> inbox() => _update((state) {
    return (state['entries'] as List)
        .cast<Map<String, dynamic>>()
        .map(RoutineNotice.fromJson)
        .toList();
  });

  Future<void> markRead({int? id}) => _update((state) {
    for (final entry
        in (state['entries'] as List).cast<Map<String, dynamic>>()) {
      if (id == null || entry['id'] == id) entry['read'] = true;
    }
  });

  static tz.Location _zone(String name) {
    try {
      return tz.getLocation(name);
    } on tz.LocationNotFoundException {
      tz_data.initializeTimeZones();
      return tz.getLocation(name);
    }
  }

  void _collectDue(Map<String, dynamic> state, DateTime now) {
    final schedule = state['schedule'] as Map<String, dynamic>?;
    if (schedule == null) return;
    final entries = (state['entries'] as List).cast<Map<String, dynamic>>();
    final zone = _zone(schedule['timezone'] as String);
    final hour = schedule['hour'] as int;
    final minute = schedule['minute'] as int;
    var next = tz.TZDateTime.from(
      DateTime.parse(schedule['next_at'] as String),
      zone,
    );
    // Only the most recent 100 daily occurrences can survive inbox retention.
    // Bound catch-up work even if the app was closed for years.
    final oldest = tz.TZDateTime.from(
      now,
      zone,
    ).subtract(const Duration(days: limit));
    if (next.isBefore(oldest)) {
      next = tz.TZDateTime(
        zone,
        oldest.year,
        oldest.month,
        oldest.day,
        hour,
        minute,
      );
    }
    while (!next.isAfter(now)) {
      // Negative IDs keep device entries separate from positive database IDs.
      final id = -next.millisecondsSinceEpoch;
      if (!entries.any((entry) => entry['id'] == id)) {
        final at = next.toUtc().toIso8601String();
        entries.add({
          'id': id,
          'source': 'daily_device',
          'title': schedule['title'],
          'body': schedule['body'],
          'weather': schedule['weather'],
          'ai_generated': false,
          'read': false,
          'created_at': at,
          'scheduled_for': at,
        });
      }
      // Calendar-day arithmetic follows the same wall-clock schedule as the
      // local notification plugin, including daylight-saving transitions.
      next = tz.TZDateTime(
        zone,
        next.year,
        next.month,
        next.day + 1,
        hour,
        minute,
      );
    }
    schedule['next_at'] = next.toUtc().toIso8601String();
    entries.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    state['entries'] = entries.take(limit).toList();
  }
}
