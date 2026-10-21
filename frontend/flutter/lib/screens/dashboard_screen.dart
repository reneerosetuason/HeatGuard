import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/heatguard_models.dart';
import '../models/mobile_account.dart';
import '../services/daily_notification_service.dart';
import '../services/routines_controller.dart';
import '../widgets/notification_sidebar.dart';
import 'routines_screen.dart';
import '../services/heatguard_api.dart';
import '../widgets/history_chart_card.dart';
import '../theme/heatguard_theme.dart';
import 'location_manager_sheet.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.api,
    this.account,
    this.onAccountSignOut,
    this.onServerChanged,
  });

  final MobileAccount? account;
  final Future<void> Function()? onAccountSignOut;
  final Future<void> Function(String)? onServerChanged;

  final HeatGuardApi? api;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  late final HeatGuardApi _api = widget.api ?? HeatGuardApi();
  final PageController _pageController = PageController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  RoutinesController? _routines;
  int _selectedTab = 0;
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
  bool _personalLocations = false;
  bool _adminConfigured = false;
  bool _isAdmin = false;
  bool _refreshing = false;
  bool _signingOutAccount = false;
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
    _routines?.dispose();
    _autoRefreshTimer?.cancel();
    _pageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (widget.account != null && _notificationsReady) {
      unawaited(_notifications.cancelDaily().catchError((Object _) {}));
    }
    if (widget.api == null) _api.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_routines?.resume());
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

      if (!mounted) return;
      if (widget.account != null) {
        _routines = RoutinesController(
          api: _api,
          baseUrl: _apiBaseUrl,
          accountId: widget.account!.id,
        )..onOpenInbox = _openInbox;
        setState(() {});
      }

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

      if (mounted) {
        unawaited(_routines?.initialize());
        setState(() {});
      }
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
        if (mounted && widget.account != null) {
          setState(() {
            _locations = [];
            _selectedLocationId = null;
            _dashboard = null;
            _loading = false;
            _error = null;
          });
          if (_notificationsReady) await _notifications.cancelDaily();
          return;
        }
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
        _error = null;
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

  Future<void> _reconnect() async {
    try {
      final capabilities = await _api.fetchMobileConfig(_apiBaseUrl);
      if (!mounted) return;
      setState(() => _applyCapabilities(capabilities));
    } catch (_) {
      // The dashboard reports connection failures and supports older servers.
    }
    if (mounted) await _loadDashboard();
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
    if (values.containsKey('can_manage_personal_locations')) {
      _personalLocations = values['can_manage_personal_locations'] == true;
    }
    _canWrite = values['can_write'] == true || _personalLocations;
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
      useRootNavigator: false,
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

  Future<void> _signOutAccount() async {
    if (_signingOutAccount || widget.onAccountSignOut == null) return;
    setState(() => _signingOutAccount = true);
    try {
      await widget.onAccountSignOut!();
    } catch (error) {
      if (mounted) _showMessage(_apiError(error));
    } finally {
      if (mounted) setState(() => _signingOutAccount = false);
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
    unawaited(_routines?.reload());
    if (mounted) _showMessage('Location added to HeatGuard monitoring.');
  }

  Future<void> _removeCurrentLocation() async {
    await _ensureWriteAccess();
    if (!mounted || !_canWrite || _dashboard == null) return;
    if (!_personalLocations && _locations.length <= 1) {
      _showMessage('At least one monitoring location must remain.');
      return;
    }
    final location = _dashboard!.location;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: const Text('Stop monitoring this location?'),
        content: Text(
          _personalLocations
              ? 'Remove ${location.name} from your addresses? Routines using it will be paused. Your other addresses stay saved.'
              : 'HeatGuard will stop monitoring ${location.name}. Its stored history will remain on the server.',
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
      unawaited(_routines?.reload());
      if (mounted) _showMessage('Stopped monitoring ${location.name}.');
    } catch (error) {
      if (mounted) _showMessage(_apiError(error));
    }
  }

  Future<void> _editApiAddress() async {
    final controller = TextEditingController(text: _apiBaseUrl);
    final value = await showDialog<String>(
      context: context,
      useRootNavigator: false,
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

    if (widget.onServerChanged != null) {
      try {
        await widget.onServerChanged!(value);
      } catch (error) {
        if (mounted) _showMessage(_apiError(error));
      }
      return;
    }
    setState(() => _apiBaseUrl = value.replaceFirst(RegExp(r'/+$'), ''));
    await _preferences.setString('api_base_url', _apiBaseUrl);
    await _reconnect();
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
      useRootNavigator: false,
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

  void _navigateTo(int index) {
    HapticFeedback.selectionClick();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(index);
    } else {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = _dashboard;
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: _routines == null
          ? null
          : NotificationSidebar(controller: _routines!),
      appBar: AppBar(
        titleSpacing: 22,
        title: Row(
          children: [
            Container(
              width: 43,
              height: 43,
              decoration: BoxDecoration(
                color: HeatGuardColors.teal,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(
                Icons.shield_outlined,
                color: Colors.white,
                size: 24,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'HeatGuard',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (MediaQuery.textScalerOf(context).scale(10) <= 14)
                    const Text(
                      'A little awareness. A safer day.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HeatGuardColors.muted,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (_routines != null) ...[
            IconButton(
              tooltip: 'My routines',
              onPressed: _openRoutines,
              icon: const Icon(Icons.event_note_outlined),
            ),
            NotificationBell(controller: _routines!, onPressed: _openInbox),
          ],
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: IconButton.outlined(
              tooltip: 'Refresh weather now',
              style: IconButton.styleFrom(
                side: const BorderSide(color: HeatGuardColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: _refreshing || _loading || dashboard == null
                  ? null
                  : _refreshNow,
              icon: _refreshing
                  ? const SizedBox.square(
                      dimension: 19,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 22),
            ),
          ),
        ],
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _selectedTab = index),
        children: [
          _page(0, [
            const _PageIntro(
              eyebrow: 'YOUR DAILY CHECK-IN',
              title: 'Stay a step ahead of the heat.',
              subtitle: 'Local conditions. A little peace of mind.',
            ),
            if (_error != null) _connectionErrorCard(_error!),
            if (dashboard == null && _loading) const _LoadingCard(),
            if (dashboard == null &&
                !_loading &&
                _error == null &&
                widget.account != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.add_home_outlined,
                        color: HeatGuardColors.teal,
                        size: 36,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Your places. Your weather.',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Save your home, school, or another address to see the weather. Your address list is private to your account.',
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _openLocationManager,
                        icon: const Icon(Icons.add_location_alt_outlined),
                        label: const Text('Add your first address'),
                      ),
                    ],
                  ),
                ),
              ),
            if (dashboard != null) ...[
              _locationSelector(dashboard),
              const SizedBox(height: 16),
              _WeatherCard(dashboard: dashboard),
              const SizedBox(height: 14),
              _ReadingStatus(dashboard: dashboard),
              const SizedBox(height: 24),
              _SectionHeading(
                title: 'Your heat outlook',
                action: 'View safety',
                onAction: () => _navigateTo(2),
              ),
              const SizedBox(height: 12),
              if (dashboard.activeAlert != null)
                _ActiveAlertCard(alert: dashboard.activeAlert!, compact: true)
              else if (dashboard.dataStatus == 'ok')
                const _NoActiveAlertCard()
              else
                const _UnavailableCard(),
              const SizedBox(height: 18),
              _RecommendationCard(
                recommendations: dashboard.recommendations,
                preview: true,
                onViewAll: () => _navigateTo(2),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _openLocationManager,
                icon: const Icon(Icons.add_location_alt_outlined, size: 19),
                label: const Text('Add a monitoring location'),
              ),
              if (_routines != null) ...[
                const SizedBox(height: 20),
                Card(
                  color: HeatGuardColors.mint,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    leading: const Icon(
                      Icons.event_available_outlined,
                      color: HeatGuardColors.teal,
                    ),
                    title: const Text(
                      'Plan your day',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Weather reminders for school, work, and everyday plans.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _openRoutines,
                  ),
                ),
              ],
            ],
          ]),
          _page(1, [
            const _PageIntro(
              eyebrow: 'THE BIGGER PICTURE',
              title: 'Follow the patterns.',
              subtitle: 'Explore how conditions change over time.',
            ),
            if (dashboard != null) ...[
              _locationSelector(dashboard),
              const SizedBox(height: 16),
              if (_error != null) _connectionErrorCard(_error!),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 8),
              HistoryChartCard(
                history: dashboard.history,
                hours: _historyHours,
                thresholds: dashboard.thresholds,
                onHoursChanged: _changeHistoryHours,
              ),
              const SizedBox(height: 18),
              _DataDetailsCard(dashboard: dashboard),
            ] else
              _dashboardPlaceholder(),
          ]),
          _page(2, [
            const _PageIntro(
              eyebrow: 'LOOK AFTER YOURSELF',
              title: 'Small steps. Safer days.',
              subtitle: 'Your local alerts and practical safety guidance.',
            ),
            if (dashboard != null) ...[
              _locationSelector(dashboard),
              const SizedBox(height: 16),
              _ReadingStatus(dashboard: dashboard),
              const SizedBox(height: 16),
              if (dashboard.activeAlert != null)
                _ActiveAlertCard(alert: dashboard.activeAlert!)
              else if (dashboard.dataStatus == 'ok')
                const _NoActiveAlertCard()
              else
                const _UnavailableCard(),
              const SizedBox(height: 18),
              _RecommendationCard(recommendations: dashboard.recommendations),
              const SizedBox(height: 18),
              _AlertHistoryCard(alerts: dashboard.alerts),
              if (dashboard.disclaimer.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 0),
                  child: Text(
                    dashboard.disclaimer,
                    style: const TextStyle(
                      color: HeatGuardColors.muted,
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ),
            ] else
              _dashboardPlaceholder(),
          ]),
          _page(3, [
            const _PageIntro(
              eyebrow: 'MAKE IT YOURS',
              title: 'A little more personal.',
              subtitle: 'Your reminders, places, and connection.',
            ),
            if (widget.account != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.verified_user_outlined,
                            color: HeatGuardColors.teal,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.account!.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                Text(
                                  widget.account!.email,
                                  style: const TextStyle(
                                    color: HeatGuardColors.muted,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                const Text(
                                  'Email verified',
                                  style: TextStyle(
                                    color: HeatGuardColors.teal,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _signingOutAccount ? null : _signOutAccount,
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        label: Text(
                          _signingOutAccount
                              ? 'Signing out...'
                              : 'Sign out of HeatGuard',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
            ],
            _ReminderCard(
              isWeb: kIsWeb,
              enabled: _dailyReminderEnabled,
              permissionGranted: _notificationPermission,
              reminderTime: TimeOfDay(
                hour: _reminderHour,
                minute: _reminderMinute,
              ),
              notificationError: _notificationError,
              dashboardAvailable: dashboard?.dataStatus == 'ok',
              onChanged: _toggleDailyReminder,
              onChooseTime: _chooseReminderTime,
            ),
            const SizedBox(height: 18),
            Card(
              child: Column(
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 8,
                    ),
                    leading: const Icon(
                      Icons.dns_outlined,
                      color: HeatGuardColors.teal,
                    ),
                    title: const Text('HeatGuard server'),
                    subtitle: Text(
                      _apiBaseUrl,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _editApiAddress,
                  ),
                  if (_isAdmin || _adminConfigured) ...[
                    const Divider(height: 1, indent: 18, endIndent: 18),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 8,
                      ),
                      leading: Icon(
                        _isAdmin
                            ? Icons.logout_rounded
                            : Icons.lock_outline_rounded,
                        color: HeatGuardColors.teal,
                      ),
                      title: Text(
                        _isAdmin
                            ? 'Administrator sign out'
                            : 'Administrator sign in',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _isAdmin ? _signOut : _signIn,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            const _SectionHeading(title: 'Monitoring locations'),
            const SizedBox(height: 12),
            if (dashboard != null) ...[
              _locationSelector(dashboard),
              const SizedBox(height: 12),
              _DashboardActions(
                refreshing: _refreshing,
                canRemove: _personalLocations || _locations.length > 1,
                canWrite: _canWrite,
                adminConfigured: _adminConfigured,
                onRefresh: _refreshNow,
                onManage: _openLocationManager,
                onRemove: _removeCurrentLocation,
                onSignIn: _signIn,
              ),
            ] else ...[
              if (_error != null) _connectionErrorCard(_error!),
              FilledButton.icon(
                onPressed: _openLocationManager,
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add location'),
              ),
            ],
            const SizedBox(height: 28),
            const Center(
              child: Text(
                'HEATGUARD  /  MINDFUL MONITORING',
                style: TextStyle(
                  color: HeatGuardColors.muted,
                  fontSize: 10,
                  letterSpacing: 1.4,
                ),
              ),
            ),
          ]),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: HeatGuardColors.border)),
        ),
        child: NavigationBar(
          selectedIndex: _selectedTab,
          onDestinationSelected: _navigateTo,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.wb_sunny_outlined),
              selectedIcon: Icon(Icons.wb_sunny_rounded),
              label: 'Today',
            ),
            NavigationDestination(
              icon: Icon(Icons.show_chart_rounded),
              label: 'Trends',
            ),
            NavigationDestination(
              icon: Icon(Icons.shield_outlined),
              selectedIcon: Icon(Icons.shield_rounded),
              label: 'Safety',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  void _openInbox() {
    if (!mounted) return;
    unawaited(_routines?.reload());
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _openRoutines() {
    final routines = _routines;
    if (routines == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            RoutinesScreen(controller: routines, locations: _locations),
      ),
    );
  }

  Widget _dashboardPlaceholder() => _loading
      ? const _LoadingCard()
      : _connectionErrorCard(
          _error ?? 'Connect to HeatGuard to load this view.',
        );

  Widget _connectionErrorCard(String message) => _ErrorCard(
    message: message,
    serverAddress: _apiBaseUrl,
    onRetry: _reconnect,
    onServerSettings: _editApiAddress,
  );

  Widget _locationSelector(HeatDashboard dashboard) => _LocationSelector(
    locations: _locations,
    selectedId: dashboard.location.id,
    enabled: !_loading,
    onChanged: _changeLocation,
  );

  Widget _page(int index, List<Widget> children) => _DashboardPage(
    child: RefreshIndicator(
      onRefresh: _loadDashboard,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            key: PageStorageKey('dashboard-tab-$index'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
            children: children,
          ),
        ),
      ),
    ),
  );
}

class _DashboardPage extends StatefulWidget {
  const _DashboardPage({required this.child});
  final Widget child;
  @override
  State<_DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<_DashboardPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _PageIntro extends StatelessWidget {
  const _PageIntro({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });
  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: const TextStyle(
            color: HeatGuardColors.teal,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.7,
          ),
        ),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: const TextStyle(
            color: HeatGuardColors.muted,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (action != null)
        TextButton(
          onPressed: onAction,
          child: Text(
            action!,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
    ],
  );
}

class _LocationSelector extends StatelessWidget {
  const _LocationSelector({
    required this.locations,
    required this.selectedId,
    required this.enabled,
    required this.onChanged,
  });
  final List<HeatLocation> locations;
  final int selectedId;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<int>(
    initialValue: locations.any((item) => item.id == selectedId)
        ? selectedId
        : null,
    key: ValueKey(selectedId),
    isExpanded: true,
    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: HeatGuardColors.ink,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    decoration: const InputDecoration(
      labelText: 'MONITORING LOCATION',
      floatingLabelBehavior: FloatingLabelBehavior.always,
      prefixIcon: Icon(
        Icons.location_on_outlined,
        color: HeatGuardColors.teal,
        size: 20,
      ),
    ),
    items: locations
        .map(
          (location) => DropdownMenuItem(
            value: location.id,
            child: Text(location.name, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: enabled ? onChanged : null,
  );
}

class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard();
  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(18),
      child: Text(
        'Current heat risk is unknown. Check local advisories while weather data is unavailable.',
        style: TextStyle(color: HeatGuardColors.muted, height: 1.5),
      ),
    ),
  );
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
  const _ActiveAlertCard({required this.alert, this.compact = false});

  final bool compact;

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
                      color: HeatGuardColors.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    alert.riskLabel,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
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
              style: const TextStyle(
                color: HeatGuardColors.muted,
                fontSize: 11,
              ),
            ),
            if (!compact && alert.recommendations.isNotEmpty) ...[
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
    color: HeatGuardColors.mint,
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, color: HeatGuardColors.teal, size: 20),
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
                      color: HeatGuardColors.ink,
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
                  style: TextStyle(color: HeatGuardColors.muted, fontSize: 13),
                ),
              )
            else
              for (var i = 0; i < alerts.length; i++) ...[
                if (i > 0)
                  const Divider(height: 18, color: HeatGuardColors.border),
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
                color: HeatGuardColors.ink,
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
              const Divider(height: 20, color: HeatGuardColors.border),
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
                      color: HeatGuardColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
            if (dashboard.riskSourceUrl?.isNotEmpty == true) ...[
              const Divider(height: 20, color: HeatGuardColors.border),
              const Text(
                'Heat index categories follow PAGASA guidance. Heat index is calculated from weather API estimates.',
                style: TextStyle(
                  color: HeatGuardColors.muted,
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 5),
              SelectableText(
                dashboard.riskSourceUrl!,
                style: const TextStyle(
                  color: HeatGuardColors.teal,
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
            style: const TextStyle(color: HeatGuardColors.muted, fontSize: 11),
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
  const _WeatherCard({required this.dashboard});
  final HeatDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final current =
        dashboard.dataStatus == 'ok' && dashboard.current?['is_stale'] != true;
    return Column(
      children: [
        Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: HeatGuardColors.deepTeal,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: HeatGuardColors.deepTeal.withValues(alpha: 0.12),
                blurRadius: 22,
                offset: const Offset(0, 9),
              ),
            ],
          ),
          child: Stack(
            children: [
              const Positioned(
                right: -30,
                top: 2,
                bottom: 0,
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 180,
                    child: CustomPaint(painter: _HeatIllustrationPainter()),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      current
                          ? 'Feels like outside'
                          : 'Last recorded heat index',
                      style: const TextStyle(
                        color: Color(0xFFCEE1D9),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 42),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: dashboard.heatIndexC ?? 0),
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 650),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, _) => Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: dashboard.heatIndexC == null
                                      ? '\u2014'
                                      : value.toStringAsFixed(1),
                                  style: const TextStyle(
                                    fontSize: 68,
                                    height: 1.12,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: -3,
                                  ),
                                ),
                                const TextSpan(
                                  text: '\u00b0C',
                                  style: TextStyle(
                                    fontSize: 30,
                                    fontWeight: FontWeight.w400,
                                    letterSpacing: -1,
                                  ),
                                ),
                              ],
                            ),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: HeatGuardColors.sand,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            current
                                ? Icons.shield_outlined
                                : Icons.info_outline_rounded,
                            size: 15,
                            color: current
                                ? _riskColor(dashboard.riskLabel)
                                : HeatGuardColors.muted,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              current
                                  ? dashboard.riskLabel
                                  : 'Current risk unknown',
                              style: TextStyle(
                                color: current
                                    ? _riskColor(dashboard.riskLabel)
                                    : HeatGuardColors.muted,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 17),
                    const Text(
                      'Calculated heat index / API estimate',
                      style: TextStyle(
                        color: Color(0xFFCEE1D9),
                        fontSize: 10,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final metrics = [
              _WeatherMetric(
                icon: Icons.thermostat_rounded,
                title: 'Air temperature',
                value: _temperature(dashboard.temperatureC),
                tint: HeatGuardColors.sand,
                iconColor: const Color(0xFF937037),
              ),
              _WeatherMetric(
                icon: Icons.water_drop_outlined,
                title: 'Humidity',
                value: dashboard.humidityPct == null
                    ? '\u2014'
                    : '${dashboard.humidityPct!.toStringAsFixed(0)}%',
                tint: const Color(0xFFEAF0F4),
                iconColor: const Color(0xFF4C7488),
              ),
            ];
            if (MediaQuery.textScalerOf(context).scale(14) > 20) {
              return Column(
                children: [metrics[0], const SizedBox(height: 10), metrics[1]],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: metrics[0]),
                const SizedBox(width: 12),
                Expanded(child: metrics[1]),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _HeatIllustrationPainter extends CustomPainter {
  const _HeatIllustrationPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.66, size.height * 0.43);
    final orbit = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFB9D4C4).withValues(alpha: 0.12);
    for (final radius in [68.0, 94.0, 121.0]) {
      canvas.drawCircle(center, radius, orbit);
    }
    final sun = Paint()
      ..color = HeatGuardColors.gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, 24, sun);
    for (var i = 0; i < 12; i++) {
      final angle = i * math.pi / 6;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(center + direction * 33, center + direction * 40, sun);
    }
    canvas.drawCircle(
      center + const Offset(-60, 60),
      3,
      Paint()..color = HeatGuardColors.gold.withValues(alpha: 0.7),
    );
    canvas.drawCircle(
      center + const Offset(-30, -90),
      2,
      Paint()..color = const Color(0xFFB9D4C4),
    );
  }

  @override
  bool shouldRepaint(covariant _HeatIllustrationPainter oldDelegate) => false;
}

class _WeatherMetric extends StatelessWidget {
  const _WeatherMetric({
    required this.icon,
    required this.title,
    required this.value,
    required this.tint,
    required this.iconColor,
  });
  final IconData icon;
  final String title;
  final String value;
  final Color tint;
  final Color iconColor;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(21),
      border: Border.all(color: HeatGuardColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 17, color: iconColor),
            ),
            const Spacer(),
            const Icon(
              Icons.sensors_rounded,
              size: 14,
              color: HeatGuardColors.muted,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          value,
          style: const TextStyle(
            color: HeatGuardColors.ink,
            fontSize: 25,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.7,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          title,
          style: const TextStyle(color: HeatGuardColors.muted, fontSize: 11),
        ),
      ],
    ),
  );
}

class _ReadingStatus extends StatelessWidget {
  const _ReadingStatus({required this.dashboard});

  final HeatDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final current = dashboard.dataStatus == 'ok';
    final color = current ? HeatGuardColors.teal : const Color(0xFF9A5A18);
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
  const _RecommendationCard({
    required this.recommendations,
    this.preview = false,
    this.onViewAll,
  });
  final List<String> recommendations;
  final bool preview;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context) {
    final tips = recommendations.isEmpty
        ? const ['Refresh HeatGuard to get the latest safety guidance.']
        : recommendations;
    final visible = preview ? tips.take(1).toList() : tips;
    return Card(
      color: preview ? const Color(0xFFF1F3E9) : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.spa_outlined,
                  size: 20,
                  color: HeatGuardColors.teal,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    preview
                        ? 'A little care goes a long way'
                        : 'Your safety guide',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < visible.length; i++) ...[
              if (i > 0) const Divider(height: 28),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!preview) ...[
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: HeatGuardColors.mint,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        '${i + 1}'.padLeft(2, '0'),
                        style: const TextStyle(
                          color: HeatGuardColors.teal,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Text(
                      visible[i],
                      style: const TextStyle(
                        color: HeatGuardColors.ink,
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (preview) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: onViewAll,
                iconAlignment: IconAlignment.end,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: const Text(
                  'Explore your safety guide',
                  style: TextStyle(fontSize: 12),
                ),
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
                          color: HeatGuardColors.muted,
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
              const Divider(height: 21, color: HeatGuardColors.border),
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
                        ? HeatGuardColors.muted
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
                      color: HeatGuardColors.muted,
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
  const _ErrorCard({
    required this.message,
    required this.serverAddress,
    required this.onRetry,
    required this.onServerSettings,
  });

  final String message;
  final String serverAddress;
  final VoidCallback onRetry;
  final VoidCallback onServerSettings;

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
                  SelectableText(
                    'Server: $serverAddress',
                    style: const TextStyle(
                      color: Color(0xFF75450F),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    children: [
                      TextButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 17),
                        label: const Text('Try again'),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          foregroundColor: const Color(0xFF75450F),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: onServerSettings,
                        icon: const Icon(Icons.tune_rounded, size: 17),
                        label: const Text('Server settings'),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          foregroundColor: const Color(0xFF75450F),
                        ),
                      ),
                    ],
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
            CircularProgressIndicator(color: HeatGuardColors.teal),
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

Color _riskColor(String risk) => HeatGuardColors.risk(risk);
