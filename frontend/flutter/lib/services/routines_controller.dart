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
    DateTime Function()? now,
  }) : _push = push ?? RoutinePushService(),
       _now = now ?? DateTime.now;
  final HeatGuardApi api;
  final String baseUrl;
  final int accountId;
  final RoutinePushService _push;
  final DateTime Function() _now;
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
  bool _pushConnected = false;
  Future<void>? _pushConnection;
  DateTime? _lastPushAttempt, _lastPushSync;
  String get _pushKey => 'routine_push:$baseUrl:$accountId';
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    await reload();
    if (!_closed && _push.isSupported) {
      pushEnabled = await _preferences.getBool(_pushKey) == true;
      _changed();
      await _restorePush();
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
      : failure is TimeoutException
      ? 'Notification setup took too long. Check your connection and try again.'
      : 'We could not complete that request. Please try again.';

  Future<void> save(Map<String, String> values, {int? id}) async {
    await api.accountSession(baseUrl);
    _requireOpen();
    await api.saveRoutine(baseUrl, values, id: id);
    await reload();
  }

  Future<void> resume() async {
    await reload();
    await _restorePush();
  }

  Future<void> _restorePush() async {
    if (_closed || busy || !pushEnabled || !_push.isSupported) return;
    final now = _now();
    if (_lastPushSync != null &&
        now.difference(_lastPushSync!) < const Duration(minutes: 5)) {
      return;
    }
    if (_lastPushAttempt != null &&
        now.difference(_lastPushAttempt!) < const Duration(seconds: 30)) {
      return;
    }
    await _connectPush(interactive: false);
  }

  Future<void> _registerToken(String token) async {
    if (_closed) return;
    try {
      await api.accountSession(baseUrl);
      _requireOpen();
      await api.registerPushDevice(baseUrl, token);
      if (!_closed) {
        _lastPushSync = _now();
        pushError = null;
        _changed();
      }
    } catch (failure) {
      _lastPushSync = null;
      pushError = message(failure);
      _changed();
      rethrow;
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
    await _connectPush(interactive: true);
  }

  Future<void> _connectPush({required bool interactive}) {
    if (_pushConnection != null) return _pushConnection!;
    final connection = _performPushConnection(interactive: interactive);
    _pushConnection = connection;
    return connection.whenComplete(() => _pushConnection = null);
  }

  Future<void> _performPushConnection({required bool interactive}) async {
    if (interactive) busy = true;
    _lastPushAttempt = _now();
    pushError = null;
    _changed();
    try {
      if (_pushConnected) {
        await _push.refresh(onToken: _registerToken);
      } else {
        await _push.enable(
          accountId: accountId,
          requestPermission: interactive,
          onToken: _registerToken,
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
        _pushConnected = true;
      }
      if (!_closed) {
        pushEnabled = true;
        await _preferences.setBool(_pushKey, true);
      }
    } catch (failure) {
      pushError = message(failure);
    } finally {
      if (interactive) busy = false;
      _changed();
    }
  }

  Future<void> disablePush() async {
    if (busy || _closed) return;
    busy = true;
    pushError = null;
    _changed();
    try {
      await _pushConnection;
      _requireOpen();
      await api.accountSession(baseUrl);
      _requireOpen();
      if (_push.token != null) {
        await api.removePushDevice(baseUrl, _push.token!);
      }
      await RoutinePushService.clearAccount(cancelNotifications: false);
      await _push.pause();
      _pushConnected = false;
      _lastPushSync = null;
      _lastPushAttempt = null;
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
