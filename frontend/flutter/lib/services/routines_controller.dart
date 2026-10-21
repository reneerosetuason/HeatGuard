import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/routine_models.dart';
import 'heatguard_api.dart';
import 'routine_push_service.dart';

class RoutinesController extends ChangeNotifier {
  RoutinesController({
    required this.api,
    required this.baseUrl,
    required this.accountId,
    RoutinePushService? push,
  }) : _push = push ?? RoutinePushService();
  final HeatGuardApi api;
  final String baseUrl;
  final int accountId;
  final RoutinePushService _push;
  final _preferences = SharedPreferencesAsync();
  List<HeatRoutine> routines = [];
  List<RoutineNotice> notices = [];
  int unread = 0;
  bool loading = true,
      busy = false,
      pushEnabled = false,
      pushAvailable = false,
      remindersEnabled = true;
  String? error, pushError;
  VoidCallback? onOpenInbox;
  Timer? _timer;
  bool _closed = false, _refreshing = false;
  String get _pushKey => 'routine_push:$baseUrl:$accountId';
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    await reload();
    if (!_closed &&
        RoutinePushService.supported &&
        await _preferences.getBool(_pushKey) == true) {
      await enablePush();
    }
    if (!_closed) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => reload());
    }
  }

  Future<void> reload() async {
    if (_closed || _refreshing) return;
    _refreshing = true;
    try {
      final data = await api.fetchRoutines(baseUrl);
      final inbox = await api.fetchNotifications(baseUrl);
      if (_closed) return;
      routines = (data['routines'] as List)
          .cast<Map<String, dynamic>>()
          .map(HeatRoutine.fromJson)
          .toList();
      notices = (inbox['notifications'] as List)
          .cast<Map<String, dynamic>>()
          .map(RoutineNotice.fromJson)
          .toList();
      unread = (inbox['unread_count'] as num).toInt();
      pushAvailable = data['push_available'] == true;
      remindersEnabled = data['reminders_enabled'] != false;
      error = null;
    } catch (failure) {
      if (!_closed) error = message(failure);
    } finally {
      loading = false;
      _refreshing = false;
      _changed();
    }
  }

  String message(Object failure) => failure is HeatGuardApiException
      ? failure.message
      : failure is StateError
      ? failure.message.toString()
      : 'We could not complete that request. Please try again.';

  Future<void> save(Map<String, String> values, {int? id}) async {
    await api.accountSession(baseUrl);
    _requireOpen();
    await api.saveRoutine(baseUrl, values, id: id);
    await reload();
  }

  Future<void> resume() async {
    await reload();
    if (!_closed &&
        RoutinePushService.supported &&
        await _preferences.getBool(_pushKey) == true) {
      await enablePush();
    }
  }

  Future<void> remove(int id) async {
    await api.accountSession(baseUrl);
    _requireOpen();
    await api.deleteRoutine(baseUrl, id);
    await reload();
  }

  Future<void> markRead({int? id}) async {
    await api.accountSession(baseUrl);
    _requireOpen();
    await api.readNotification(baseUrl, id: id);
    await reload();
  }

  Future<Map<String, dynamic>> preview(int id) async {
    await api.accountSession(baseUrl);
    _requireOpen();
    return api.previewRoutine(baseUrl, id);
  }

  void _requireOpen() {
    if (_closed) throw StateError('Your session has ended. Sign in again.');
  }

  Future<void> enablePush() async {
    if (busy || _closed) return;
    busy = true;
    pushError = null;
    _changed();
    try {
      await _push.enable(
        accountId: accountId,
        onToken: (token) async {
          if (_closed) return;
          await api.accountSession(baseUrl);
          if (!_closed) await api.registerPushDevice(baseUrl, token);
        },
        onMessage: () => reload(),
        onOpen: (id) async {
          if (_closed) return;
          if (id != null) {
            try {
              await markRead(id: id);
            } catch (_) {}
          }
          if (!_closed) onOpenInbox?.call();
        },
      );
      if (!_closed) {
        pushEnabled = true;
        await _preferences.setBool(_pushKey, true);
      }
    } catch (failure) {
      pushError = message(failure);
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> disablePush() async {
    if (busy) return;
    busy = true;
    _changed();
    try {
      await api.accountSession(baseUrl);
      if (_push.token != null) {
        await api.removePushDevice(baseUrl, _push.token!);
      }
      await RoutinePushService.clearAccount(cancelNotifications: false);
      await _push.pause();
      await _preferences.setBool(_pushKey, false);
      pushEnabled = false;
    } catch (failure) {
      pushError = message(failure);
    } finally {
      busy = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    unawaited(_push.dispose());
    super.dispose();
  }
}
