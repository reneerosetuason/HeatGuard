import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/heatguard_models.dart';
import '../services/daily_notification_service.dart';
import '../services/heatguard_api.dart';
import '../widgets/history_chart_card.dart';
import 'location_manager_sheet.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  final HeatGuardApi _api = HeatGuardApi();
  final DailyNotificationService _notifications = DailyNotificationService();

  List<HeatLocation> _locations = const [];
  HeatDashboard? _dashboard;
  int? _selectedLocationId;
  String _apiBaseUrl = HeatGuardApi.defaultBaseUrl;
  String? _error;
  String? _notificationError;
  bool _loading = true;
  bool _notificationsReady = false;
  bool _notificationPermission = false;
  bool _dailyReminderEnabled = true;
  bool _canWrite = false;
  bool _adminConfigured = false;
  bool _isAdmin = false;
  bool _refreshing = false;
  int _reminderHour = 8;
  int _reminderMinute = 0;
  int _historyHours = 24;
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          !_loading) {
        _loadDashboard(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _api.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) {
      _loadDashboard(silent: true);
    }
  }

  Future<void> _initialize() async {
    try {
      final savedBaseUrl = await _preferences.getString('api_base_url');
      final savedLocationId = await _preferences.getInt('location_id');
      final savedReminder = await _preferences.getBool('daily_reminder');
      final savedHour = await _preferences.getInt('reminder_hour');
      final savedMinute = await _preferences.getInt('reminder_minute');
      final savedHistoryHours = await _preferences.getInt('history_hours');

      _apiBaseUrl = savedBaseUrl ?? HeatGuardApi.defaultBaseUrl;
      if (kIsWeb && _apiBaseUrl == 'http://127.0.0.1:5000') {
        _apiBaseUrl = HeatGuardApi.defaultBaseUrl;
        await _preferences.setString('api_base_url', _apiBaseUrl);
      }
      _selectedLocationId = savedLocationId;
      _dailyReminderEnabled = savedReminder ?? true;
      _reminderHour = savedHour ?? 8;
      _reminderMinute = savedMinute ?? 0;
      _historyHours = savedHistoryHours == 168 ? 168 : 24;

      try {
        _applyCapabilities(await _api.fetchMobileConfig(_apiBaseUrl));
      } catch (_) {
        // Dashboard reads remain available when this optional endpoint is unavailable.
      }

      if (kIsWeb) {
        _dailyReminderEnabled = false;
        _notificationError =
            'Device notifications are available in the Android and iOS app.';
      } else {
        try {
          await _notifications.initialize();
          _notificationsReady = true;
          if (_dailyReminderEnabled) {
            _notificationPermission = await _notifications.requestPermission();
            if (!_notificationPermission) {
              _dailyReminderEnabled = false;
              _notificationError =
                  'Allow notifications for HeatGuard to receive the daily update.';
              await _preferences.setBool('daily_reminder', false);
            }
          }
        } catch (error) {
          _notificationError = 'Device notifications could not be initialized.';
          _dailyReminderEnabled = false;
        }
      }

      if (mounted) setState(() {});
      await _loadDashboard();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'HeatGuard could not load its saved settings.';
        _loading = false;
      });
    }
  }

  Future<void> _loadDashboard({bool silent = false}) async {
    if (_loading && _dashboard != null) return;
    if (!silent || _dashboard == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final locations = await _api.fetchLocations(_apiBaseUrl);
      if (locations.isEmpty) {
        throw const HeatGuardApiException(
          'No monitoring locations are configured in HeatGuard yet.',
        );
      }

      var locationId = _selectedLocationId;
      if (locationId == null ||
          !locations.any((item) => item.id == locationId)) {
        final savedId = await _preferences.getInt('location_id');
        locationId = locations.any((item) => item.id == savedId)
            ? savedId
            : locations.first.id;
      }

      final dashboard = await _api.fetchDashboard(
        _apiBaseUrl,
        locationId: locationId!,
        hours: _historyHours,
      );
      if (!mounted) return;
      final previousReadingAt = _dashboard?.current?['observed_at'];
      setState(() {
        _locations = locations;
        _selectedLocationId = dashboard.location.id;
        _dashboard = dashboard;
        _loading = false;
      });
      await _preferences.setInt('location_id', dashboard.location.id);

      if (_dailyReminderEnabled &&
          _notificationPermission &&
          previousReadingAt != dashboard.current?['observed_at']) {
        await _scheduleDailyReminder(dashboard);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is HeatGuardApiException
            ? error.message
            : 'HeatGuard could not refresh its dashboard.';
        _loading = false;
      });
    }
  }

  Future<void> _scheduleDailyReminder(HeatDashboard dashboard) async {
    try {
      await _notifications.scheduleDaily(
        dashboard,
        hour: _reminderHour,
        minute: _reminderMinute,
      );
      if (mounted && _notificationError != null) {
        setState(() => _notificationError = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _notificationError =
              'HeatGuard could not schedule the daily notification.';
        });
      }
    }
  }

  Future<void> _changeLocation(int? locationId) async {
    if (locationId == null || locationId == _selectedLocationId) return;
    setState(() => _selectedLocationId = locationId);
    await _preferences.setInt('location_id', locationId);
    await _loadDashboard();
  }

  Future<void> _changeHistoryHours(int hours) async {
    if (hours == _historyHours) return;
    setState(() => _historyHours = hours);
    await _preferences.setInt('history_hours', hours);
    await _loadDashboard();
  }

  void _applyCapabilities(Map<String, dynamic> values) {
    _canWrite = values['can_write'] == true;
    _adminConfigured = values['admin_configured'] == true;
    _isAdmin = values['is_admin'] == true;
  }

  Future<void> _ensureWriteAccess() async {
    if (_canWrite) return;
    if (_adminConfigured) {
      await _signIn();
    } else {
      _showMessage(
        'Changes are restricted to the HeatGuard host. Configure an administrator account to manage locations from this device.',
      );
    }
  }

  Future<void> _signIn() async {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final credentials = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('HeatGuard administrator sign in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passwordController,
              obscureText: true,
              onSubmitted: (_) => Navigator.pop(dialogContext, {
                'username': usernameController.text.trim(),
                'password': passwordController.text,
              }),
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'username': usernameController.text.trim(),
              'password': passwordController.text,
            }),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    usernameController.dispose();
    passwordController.dispose();
    if (credentials == null || !mounted) return;

    try {
      final result = await _api.login(
        _apiBaseUrl,
        username: credentials['username'] ?? '',
        password: credentials['password'] ?? '',
      );
      if (!mounted) return;
      setState(() => _applyCapabilities(result));
      if (_canWrite) {
        _showMessage('Signed in. Location management and refresh are enabled.');
      } else {
        _showMessage('HeatGuard did not grant write access to this session.');
      }
    } catch (error) {
      if (mounted) _showMessage(_apiError(error));
    }
  }

  Future<void> _signOut() async {
    try {
      final result = await _api.logout(_apiBaseUrl);
      if (!mounted) return;
      setState(() => _applyCapabilities(result));
      _showMessage('Signed out of HeatGuard.');
    } catch (error) {
      if (mounted) _showMessage(_apiError(error));
    }
  }

  Future<void> _refreshNow() async {
    if (_refreshing || _selectedLocationId == null) return;
    await _ensureWriteAccess();
    if (!mounted || !_canWrite) return;
    setState(() => _refreshing = true);
    try {
      final result = await _api.refreshNow(
        _apiBaseUrl,
        locationId: _selectedLocationId!,
        hours: _historyHours,
      );
      final rawDashboard = result['dashboard'];
      if (rawDashboard is Map<String, dynamic> && mounted) {
        final dashboard = HeatDashboard.fromJson(rawDashboard);
        setState(() {
          _dashboard = dashboard;
          _locations = dashboard.locations;
          _selectedLocationId = dashboard.location.id;
        });
        if (_dailyReminderEnabled && _notificationPermission) {
          await _scheduleDailyReminder(dashboard);
        }
      }
      if (mounted) {
        _showMessage(
          (result['message'] ?? 'Weather data refreshed.').toString(),
        );
      }
    } catch (error) {
      if (error is HeatGuardApiException &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        setState(() {
          _canWrite = false;
          _isAdmin = false;
        });
      }
      if (mounted) _showMessage(_apiError(error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _apiError(Object error) => error is HeatGuardApiException
      ? error.message
      : 'HeatGuard could not complete this request.';

  Future<void> _openLocationManager() async {
    await _ensureWriteAccess();
    if (!mounted || !_canWrite) return;
    final newLocationId = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (context) =>
          LocationManagerSheet(api: _api, baseUrl: _apiBaseUrl),
    );
    if (newLocationId == null || !mounted) return;
    setState(() => _selectedLocationId = newLocationId);
    await _preferences.setInt('location_id', newLocationId);
    await _loadDashboard();
    if (mounted) _showMessage('Location added to HeatGuard monitoring.');
  }

  Future<void> _removeCurrentLocation() async {
    await _ensureWriteAccess();
    if (!mounted || !_canWrite || _dashboard == null) return;
    if (_locations.length <= 1) {
      _showMessage('At least one monitoring location must remain.');
      return;
    }
    final location = _dashboard!.location;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop monitoring this location?'),
        content: Text(
          'HeatGuard will stop monitoring ${location.name}. Its stored history will remain on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep location'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop monitoring'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _api.deleteLocation(_apiBaseUrl, location.id);
      setState(() => _selectedLocationId = null);
      await _preferences.remove('location_id');
      await _loadDashboard();
      if (mounted) _showMessage('Stopped monitoring ${location.name}.');
    } catch (error) {
      if (mounted) _showMessage(_apiError(error));
    }
  }

  Future<void> _editApiAddress() async {
    final controller = TextEditingController(text: _apiBaseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('HeatGuard server'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'API base address',
            hintText: 'https://heatguard.example.com',
            helperText: 'Use the same server that hosts your HeatGuard API.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;

    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _showMessage(
        'Enter a complete server address starting with http:// or https://.',
      );
      return;
    }

    setState(() => _apiBaseUrl = value.replaceFirst(RegExp(r'/+$'), ''));
    await _preferences.setString('api_base_url', _apiBaseUrl);
    await _loadDashboard();
  }

  Future<void> _toggleDailyReminder(bool enabled) async {
    if (kIsWeb) {
      _showMessage(
        'Device reminders are supported in the Android and iOS app.',
      );
      return;
    }
    if (!enabled) {
      await _notifications.cancelDaily();
      await _preferences.setBool('daily_reminder', false);
      if (mounted) {
        setState(() {
          _dailyReminderEnabled = false;
          _notificationError = null;
        });
      }
      return;
    }

    try {
      if (!_notificationsReady) {
        await _notifications.initialize();
        _notificationsReady = true;
      }
      final permission = await _notifications.requestPermission();
      if (!mounted) return;
      setState(() {
        _notificationPermission = permission;
        _dailyReminderEnabled = permission;
        _notificationError = permission
            ? null
            : 'Allow notifications for HeatGuard in your device settings.';
      });
      await _preferences.setBool('daily_reminder', permission);
      if (permission && _dashboard != null) {
        await _scheduleDailyReminder(_dashboard!);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _dailyReminderEnabled = false;
        _notificationError = 'HeatGuard could not enable device notifications.';
      });
      await _preferences.setBool('daily_reminder', false);
    }
  }

  Future<void> _chooseReminderTime() async {
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _reminderHour, minute: _reminderMinute),
      helpText: 'Choose your daily HeatGuard update time',
    );
    if (selected == null || !mounted) return;

    setState(() {
      _reminderHour = selected.hour;
      _reminderMinute = selected.minute;
    });
    await _preferences.setInt('reminder_hour', selected.hour);
    await _preferences.setInt('reminder_minute', selected.minute);
    if (_dailyReminderEnabled &&
        _notificationPermission &&
        _dashboard != null) {
      await _scheduleDailyReminder(_dashboard!);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = _dashboard;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFE1F0E8),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.wb_sunny_rounded,
                color: Color(0xFF17624A),
                size: 22,
              ),
            ),
            const SizedBox(width: 11),
            const Text('HeatGuard'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh weather now',
            onPressed: _refreshing ? null : _refreshNow,
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: 'Account and server settings',
            onSelected: (value) {
              if (value == 'sign_in') _signIn();
              if (value == 'sign_out') _signOut();
              if (value == 'server') _editApiAddress();
            },
            itemBuilder: (context) => [
              if (_isAdmin)
                const PopupMenuItem(
                  value: 'sign_out',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.logout_rounded),
                    title: Text('Sign out'),
                  ),
                )
              else if (_adminConfigured)
                const PopupMenuItem(
                  value: 'sign_in',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.login_rounded),
                    title: Text('Administrator sign in'),
                  ),
                ),
              const PopupMenuItem(
                value: 'server',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.tune_rounded),
                  title: Text('Server settings'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xFF17624A),
        onRefresh: _loadDashboard,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
          children: [
            const Text(
              'Heat safety, at a glance.',
              style: TextStyle(
                color: Color(0xFF15251E),
                fontSize: 27,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Local conditions and practical guidance for today.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            if (_error != null)
              _ErrorCard(message: _error!, onRetry: _loadDashboard),
            if (dashboard == null && _loading)
              const _LoadingCard()
            else if (dashboard != null) ...[
              _WeatherCard(
                dashboard: dashboard,
                locations: _locations,
                selectedLocationId: _selectedLocationId,
                onLocationChanged: _changeLocation,
              ),
              const SizedBox(height: 12),
              _ReadingStatus(dashboard: dashboard),
              const SizedBox(height: 12),
              _DashboardActions(
                refreshing: _refreshing,
                canRemove: _locations.length > 1,
                canWrite: _canWrite,
                adminConfigured: _adminConfigured,
                onRefresh: _refreshNow,
                onManage: _openLocationManager,
                onRemove: _removeCurrentLocation,
                onSignIn: _signIn,
              ),
              const SizedBox(height: 20),
              if (dashboard.activeAlert != null) ...[
                _ActiveAlertCard(alert: dashboard.activeAlert!),
                const SizedBox(height: 16),
              ] else if (dashboard.dataStatus == 'ok') ...[
                const _NoActiveAlertCard(),
                const SizedBox(height: 16),
              ],
              HistoryChartCard(
                history: dashboard.history,
                hours: _historyHours,
                thresholds: dashboard.thresholds,
                onHoursChanged: _changeHistoryHours,
              ),
              const SizedBox(height: 16),
              _RecommendationCard(recommendations: dashboard.recommendations),
              const SizedBox(height: 16),
              _AlertHistoryCard(alerts: dashboard.alerts),
              const SizedBox(height: 16),
              _DataDetailsCard(dashboard: dashboard),
              const SizedBox(height: 16),
              _ReminderCard(
                isWeb: kIsWeb,
                enabled: _dailyReminderEnabled,
                permissionGranted: _notificationPermission,
                reminderTime: TimeOfDay(
                  hour: _reminderHour,
                  minute: _reminderMinute,
                ),
                notificationError: _notificationError,
                dashboardAvailable: dashboard.dataStatus == 'ok',
                onChanged: _toggleDailyReminder,
                onChooseTime: _chooseReminderTime,
              ),
              if (dashboard.disclaimer.isNotEmpty) ...[
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    dashboard.disclaimer,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF7C8B82),
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _DashboardActions extends StatelessWidget {
  const _DashboardActions({
    required this.refreshing,
    required this.canRemove,
    required this.canWrite,
    required this.adminConfigured,
    required this.onRefresh,
    required this.onManage,
    required this.onRemove,
    required this.onSignIn,
  });

  final bool refreshing;
  final bool canRemove;
  final bool canWrite;
  final bool adminConfigured;
  final VoidCallback onRefresh;
  final VoidCallback onManage;
  final VoidCallback onRemove;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: refreshing ? null : onRefresh,
          icon: refreshing
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Refresh now'),
        ),
        OutlinedButton.icon(
          onPressed: onManage,
          icon: const Icon(Icons.add_location_alt_outlined, size: 18),
          label: const Text('Add location'),
        ),
        if (canRemove)
          OutlinedButton.icon(
            onPressed: onRemove,
            icon: const Icon(Icons.location_off_outlined, size: 18),
            label: const Text('Stop monitoring'),
          ),
        if (!canWrite && adminConfigured)
          OutlinedButton.icon(
            onPressed: onSignIn,
            icon: const Icon(Icons.login_rounded, size: 18),
            label: const Text('Administrator sign in'),
          ),
      ],
    );
  }
}

class _ActiveAlertCard extends StatelessWidget {
  const _ActiveAlertCard({required this.alert});

  final HeatAlert alert;

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(alert.riskLabel);
    return Card(
      color: const Color(0xFFFFF9F1),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 5)),
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: color, size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Active heat alert',
                    style: TextStyle(
                      color: Color(0xFF15251E),
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  alert.riskLabel,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              alert.message,
              style: const TextStyle(
                color: Color(0xFF45564D),
                height: 1.4,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              [
                if (alert.generatedAtDisplay?.isNotEmpty ?? false)
                  'Generated ${alert.generatedAtDisplay}',
                if (alert.heatIndexC != null)
                  'Heat index ${alert.heatIndexC!.toStringAsFixed(1)}°C',
              ].join('  ·  '),
              style: const TextStyle(color: Color(0xFF77867E), fontSize: 11),
            ),
            if (alert.recommendations.isNotEmpty) ...[
              const Divider(height: 22, color: Color(0xFFE9E4DB)),
              for (var i = 0; i < alert.recommendations.length; i++) ...[
                if (i > 0) const SizedBox(height: 7),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle_outline, size: 16, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        alert.recommendations[i],
                        style: const TextStyle(
                          color: Color(0xFF45564D),
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _NoActiveAlertCard extends StatelessWidget {
  const _NoActiveAlertCard();

  @override
  Widget build(BuildContext context) => Card(
    color: const Color(0xFFEAF4ED),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, color: Color(0xFF17624A), size: 20),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              'No active heat alert. Keep checking conditions and follow local advisories.',
              style: TextStyle(
                color: Color(0xFF315D48),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _AlertHistoryCard extends StatelessWidget {
  const _AlertHistoryCard({required this.alerts});

  final List<HeatAlert> alerts;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 16, 17, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Recent heat alerts',
                    style: TextStyle(
                      color: Color(0xFF15251E),
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF1EC),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Text(
                    '${alerts.length}',
                    style: const TextStyle(
                      color: Color(0xFF4E6256),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (alerts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'No heat alerts have been recorded for this location yet.',
                  style: TextStyle(color: Color(0xFF77867E), fontSize: 13),
                ),
              )
            else
              for (var i = 0; i < alerts.length; i++) ...[
                if (i > 0) const Divider(height: 18, color: Color(0xFFEEF1EE)),
                _AlertHistoryRow(alert: alerts[i]),
              ],
          ],
        ),
      ),
    );
  }
}

class _AlertHistoryRow extends StatelessWidget {
  const _AlertHistoryRow({required this.alert});

  final HeatAlert alert;

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(alert.riskLabel);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 4,
          height: 43,
          margin: const EdgeInsets.only(right: 11, top: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alert.riskLabel,
                      style: const TextStyle(
                        color: Color(0xFF25372D),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (alert.heatIndexC != null)
                    Text(
                      '${alert.heatIndexC!.toStringAsFixed(1)}°C',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                [
                  if (alert.generatedAtDisplay?.isNotEmpty ?? false)
                    alert.generatedAtDisplay!,
                  if (alert.temperatureC != null)
                    'Air ${alert.temperatureC!.toStringAsFixed(1)}°C',
                  if (alert.humidityPct != null)
                    '${alert.humidityPct!.toStringAsFixed(0)}% RH',
                ].join('  ·  '),
                style: const TextStyle(color: Color(0xFF7B8981), fontSize: 11),
              ),
              if (alert.message.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  alert.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF55645C),
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DataDetailsCard extends StatelessWidget {
  const _DataDetailsCard({required this.dashboard});

  final HeatDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final current = dashboard.current;
    final source = current?['source']?.toString();
    final observed = dashboard.observedAtDisplay;
    final age = current?['is_stale'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Data details',
              style: TextStyle(
                color: Color(0xFF15251E),
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _DetailLine(
              icon: Icons.schedule_outlined,
              label: 'Observation time',
              value: observed ?? 'No validated reading',
            ),
            _DetailLine(
              icon: Icons.cloud_done_outlined,
              label: 'Last successful update',
              value: dashboard.lastSuccessAtDisplay ?? 'Not available',
            ),
            _DetailLine(
              icon: Icons.source_outlined,
              label: 'Weather source',
              value: source?.isNotEmpty == true ? source! : 'Not available',
            ),
            if (dashboard.staleAfterSeconds != null)
              _DetailLine(
                icon: Icons.hourglass_bottom_rounded,
                label: 'Stale after',
                value: '${dashboard.staleAfterSeconds! ~/ 60} minutes',
              ),
            if (age)
              const Padding(
                padding: EdgeInsets.only(top: 5, bottom: 7),
                child: Text(
                  'This reading is historical; current conditions are unknown.',
                  style: TextStyle(
                    color: Color(0xFF9A5A18),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            if (dashboard.lastError != null) ...[
              const Divider(height: 20, color: Color(0xFFEEF1EE)),
              Text(
                'Last update issue: ${dashboard.lastError!['message'] ?? 'Weather update failed.'}',
                style: const TextStyle(
                  color: Color(0xFF9A5A18),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              if (dashboard.lastError!['at_display'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    'At ${dashboard.lastError!['at_display']}',
                    style: const TextStyle(
                      color: Color(0xFF89958E),
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
            if (dashboard.riskSourceUrl?.isNotEmpty == true) ...[
              const Divider(height: 20, color: Color(0xFFEEF1EE)),
              const Text(
                'Heat index categories follow PAGASA guidance. Heat index is calculated from weather API estimates.',
                style: TextStyle(
                  color: Color(0xFF77867E),
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 5),
              SelectableText(
                dashboard.riskSourceUrl!,
                style: const TextStyle(
                  color: Color(0xFF17624A),
                  fontSize: 11,
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF738178)),
        const SizedBox(width: 8),
        SizedBox(
          width: 135,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF77867E), fontSize: 11),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Color(0xFF45564D),
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ),
      ],
    ),
  );
}

class _WeatherCard extends StatelessWidget {
  const _WeatherCard({
    required this.dashboard,
    required this.locations,
    required this.selectedLocationId,
    required this.onLocationChanged,
  });

  final HeatDashboard dashboard;
  final List<HeatLocation> locations;
  final int? selectedLocationId;
  final ValueChanged<int?> onLocationChanged;

  @override
  Widget build(BuildContext context) {
    final riskColor = _riskColor(dashboard.riskLabel);
    final heatIndex = dashboard.heatIndexC;
    final temperature = dashboard.temperatureC;
    final humidity = dashboard.humidityPct;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(21, 18, 21, 21),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1F7657), Color(0xFF104A3A)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x24104A3A),
            blurRadius: 22,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.place_rounded, size: 17, color: Colors.white70),
              const SizedBox(width: 5),
              Expanded(
                child: locations.isEmpty
                    ? Text(
                        dashboard.location.name,
                        style: const TextStyle(color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      )
                    : DropdownButton<int>(
                        value:
                            locations.any(
                              (item) => item.id == selectedLocationId,
                            )
                            ? selectedLocationId
                            : dashboard.location.id,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        iconEnabledColor: Colors.white70,
                        dropdownColor: const Color(0xFF17624A),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                        items: locations
                            .map(
                              (location) => DropdownMenuItem<int>(
                                value: location.id,
                                child: Text(
                                  location.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: onLocationChanged,
                      ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: riskColor.withValues(alpha: 0.17),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: riskColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  dashboard.riskLabel,
                  style: TextStyle(
                    color: _riskTextColor(dashboard.riskLabel),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 23),
          const Text(
            'HEAT INDEX',
            style: TextStyle(
              color: Color(0xFFB8D5C5),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                heatIndex == null ? '—' : '${heatIndex.toStringAsFixed(1)}°',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 55,
                  height: 1.05,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -2,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 9, left: 4),
                child: Text(
                  'C',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.wb_sunny_rounded,
                color: Color(0xFFFFD27A),
                size: 42,
              ),
            ],
          ),
          const SizedBox(height: 13),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _WeatherMetric(
                icon: Icons.thermostat_rounded,
                label: 'Air ${_temperature(temperature)}',
              ),
              _WeatherMetric(
                icon: Icons.water_drop_outlined,
                label:
                    'Humidity ${humidity == null ? '—' : '${humidity.toStringAsFixed(0)}%'}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WeatherMetric extends StatelessWidget {
  const _WeatherMetric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: const Color(0xFFC2D8CC)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ],
    );
  }
}

class _ReadingStatus extends StatelessWidget {
  const _ReadingStatus({required this.dashboard});

  final HeatDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final current = dashboard.dataStatus == 'ok';
    final color = current ? const Color(0xFF17624A) : const Color(0xFF9A5A18);
    final background = current
        ? const Color(0xFFE5F2EA)
        : const Color(0xFFFFF1D9);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            current ? Icons.check_circle_rounded : Icons.info_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              dashboard.statusMessage.isEmpty
                  ? (current
                        ? 'Weather data is current.'
                        : 'Current weather is unavailable.')
                  : dashboard.statusMessage,
              style: TextStyle(
                color: color,
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.recommendations});

  final List<String> recommendations;

  @override
  Widget build(BuildContext context) {
    final tips = recommendations.isEmpty
        ? const ['Refresh HeatGuard to get the latest safety guidance.']
        : recommendations;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9F2EC),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.volunteer_activism_rounded,
                    color: Color(0xFF17624A),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 11),
                Text(
                  'Today’s recommendations',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 15),
            for (var index = 0; index < tips.length; index++) ...[
              if (index > 0)
                const Divider(height: 18, color: Color(0xFFEEF1EE)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Icon(
                      Icons.circle,
                      size: 7,
                      color: Color(0xFF3D9973),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      tips[index],
                      style: const TextStyle(
                        color: Color(0xFF45564D),
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({
    required this.isWeb,
    required this.enabled,
    required this.permissionGranted,
    required this.reminderTime,
    required this.notificationError,
    required this.dashboardAvailable,
    required this.onChanged,
    required this.onChooseTime,
  });

  final bool isWeb;
  final bool enabled;
  final bool permissionGranted;
  final TimeOfDay reminderTime;
  final String? notificationError;
  final bool dashboardAvailable;
  final ValueChanged<bool> onChanged;
  final VoidCallback onChooseTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = isWeb
        ? 'Device notifications are available in the Android and iOS app.'
        : notificationError ??
              (!permissionGranted && enabled
                  ? 'Allow notifications for HeatGuard in your device settings.'
                  : enabled && !dashboardAvailable
                  ? 'Connect to HeatGuard once to add weather to the daily update.'
                  : enabled
                  ? 'Weather and a safety tip will appear in your device notifications.'
                  : 'Daily weather and safety reminders are paused.');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 15, 14, 15),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF2DD),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.notifications_active_rounded,
                    color: Color(0xFFB66A19),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Daily device reminder',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Weather + a safety recommendation',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF77867E),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: enabled,
                  onChanged: isWeb ? null : onChanged,
                ),
              ],
            ),
            if (enabled) ...[
              const Divider(height: 21, color: Color(0xFFEEF1EE)),
              Row(
                children: [
                  const Icon(
                    Icons.schedule_rounded,
                    size: 17,
                    color: Color(0xFF66766D),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Every day',
                      style: TextStyle(
                        color: Color(0xFF45564D),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onChooseTime,
                    child: Text(reminderTime.format(context)),
                  ),
                ],
              ),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 2, top: 5),
                child: Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: notificationError == null
                        ? const Color(0xFF77867E)
                        : const Color(0xFF9A5A18),
                    height: 1.35,
                  ),
                ),
              ),
            ),
            if (enabled && dashboardAvailable)
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 2, top: 6),
                  child: Text(
                    'The scheduled message uses the latest reading saved by the app.',
                    style: TextStyle(
                      color: Color(0xFF96A199),
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFF5E7),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.cloud_off_rounded, color: Color(0xFF9A5A18)),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: const TextStyle(color: Color(0xFF75450F)),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text('Try again'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      foregroundColor: const Color(0xFF75450F),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 46),
        child: Column(
          children: [
            CircularProgressIndicator(color: Color(0xFF17624A)),
            SizedBox(height: 16),
            Text('Loading local heat conditions…'),
          ],
        ),
      ),
    );
  }
}

String _temperature(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)}°C';

Color _riskColor(String risk) {
  final label = risk.toLowerCase();
  if (label.contains('extreme danger')) {
    return const Color(0xFFF09BAD);
  }
  if (label.contains('danger')) return const Color(0xFFFF9585);
  if (label.contains('extreme caution') || label.contains('very high')) {
    return const Color(0xFFFFB27F);
  }
  if (label.contains('caution') || label.contains('moderate')) {
    return const Color(0xFFFFD27A);
  }
  if (label.contains('low')) return const Color(0xFF90D4AA);
  return const Color(0xFFC8DAD0);
}

Color _riskTextColor(String risk) {
  final label = risk.toLowerCase();
  if (label.contains('extreme danger') || label.contains('danger')) {
    return const Color(0xFFFFE2DC);
  }
  if (label.contains('extreme caution') || label.contains('very high')) {
    return const Color(0xFFFFE0C5);
  }
  if (label.contains('caution') || label.contains('moderate')) {
    return const Color(0xFFFFE9BD);
  }
  if (label.contains('low')) return const Color(0xFFD7F4DF);
  return Colors.white;
}
