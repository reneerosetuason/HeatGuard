import 'dart:async';
import 'package:flutter/material.dart';
import '../models/heatguard_models.dart';
import '../models/routine_models.dart';
import '../services/routine_push_service.dart';
import '../services/routines_controller.dart';
import '../theme/heatguard_theme.dart';
import '../widgets/notification_sidebar.dart';

class RoutinesScreen extends StatefulWidget {
  const RoutinesScreen({
    super.key,
    required this.controller,
    required this.locations,
  });
  final RoutinesController controller;
  final List<HeatLocation> locations;
  @override
  State<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends State<RoutinesScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();
  late List<HeatLocation> _places = widget.locations;
  VoidCallback? _previousOpen;
  int? _previewing;
  RoutinesController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _previousOpen = controller.onOpenInbox;
    controller.onOpenInbox = _openInbox;
    if (_places.isEmpty) unawaited(_loadLocations());
  }

  void _openInbox() {
    unawaited(controller.reload());
    if (mounted) _scaffold.currentState?.openEndDrawer();
  }

  Future<void> _loadLocations() async {
    try {
      final places = await controller.api.fetchLocations(controller.baseUrl);
      if (mounted) setState(() => _places = places);
    } catch (_) {}
  }

  @override
  void dispose() {
    controller.onOpenInbox = _previousOpen;
    super.dispose();
  }

  void _error(Object error) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(controller.message(error))));
  Future<void> _edit([HeatRoutine? routine]) async {
    if (_places.isEmpty) await _loadLocations();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: false,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: HeatGuardColors.background,
      builder: (_) => _RoutineEditor(
        controller: controller,
        locations: _places,
        routine: routine,
      ),
    );
  }

  Future<void> _delete(HeatRoutine routine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: const Text('Delete routine?'),
        content: Text(
          'Remove “${routine.title}”? Your past notifications will stay in the inbox.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await controller.remove(routine.id);
      } catch (error) {
        if (mounted) _error(error);
      }
    }
  }

  Future<void> _preview(HeatRoutine routine) async {
    setState(() => _previewing = routine.id);
    try {
      final result = await controller.preview(routine.id);
      if (!mounted) return;
      final preview = result['preview'] as Map<String, dynamic>;
      await showDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          title: const Text('Reminder preview'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview['title'] as String,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(preview['body'] as String),
                const SizedBox(height: 16),
                Text(
                  preview['ai_generated'] == true
                      ? 'Personalized with AI using the weather forecast.'
                      : 'Prepared from weather guidance.',
                  style: const TextStyle(
                    color: HeatGuardColors.teal,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Preview only. Your reminder is sent at the time you chose.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _error(error);
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      key: _scaffold,
      appBar: AppBar(
        title: const Text('My routines'),
        actions: [
          NotificationBell(controller: controller, onPressed: _openInbox),
          const SizedBox(width: 12),
        ],
      ),
      endDrawer: NotificationSidebar(controller: controller),
      body: RefreshIndicator(
        onRefresh: controller.reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 30),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 740),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'A SMALL PLAN. A SAFER DAY.',
                      style: TextStyle(
                        color: HeatGuardColors.teal,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Make room for what matters.',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Plan school, work, or a walk. Get a weather heads-up before it is time to leave.',
                    ),
                    const SizedBox(height: 22),
                    Card(
                      color: HeatGuardColors.mint,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.notifications_active_outlined,
                              color: HeatGuardColors.teal,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              controller.pushEnabled
                                  ? 'Phone notifications are on.'
                                  : 'Your next little heads-up.',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: HeatGuardColors.ink,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              RoutinePushService.supported
                                  ? 'Weather reminders appear on your phone and in your notification inbox.'
                                  : 'Your reminders appear in the notification inbox. Use the Android app for phone push notifications.',
                            ),
                            if (controller.pushError != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                controller.pushError!,
                                style: const TextStyle(
                                  color: Color(0xFF874C22),
                                ),
                              ),
                            ],
                            if (RoutinePushService.supported) ...[
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed:
                                    controller.busy || !controller.pushAvailable
                                    ? null
                                    : controller.pushEnabled
                                    ? controller.disablePush
                                    : controller.enablePush,
                                icon: Icon(
                                  controller.pushEnabled
                                      ? Icons.notifications_off_outlined
                                      : Icons.notifications_active_outlined,
                                ),
                                label: Text(
                                  controller.busy
                                      ? controller.pushEnabled
                                            ? 'Pausing…'
                                            : 'Connecting…'
                                      : controller.pushEnabled
                                      ? 'Pause phone notifications'
                                      : 'Enable phone notifications',
                                ),
                              ),
                            ],
                            if (!controller.remindersEnabled ||
                                (RoutinePushService.supported &&
                                    !controller.pushAvailable)) ...[
                              const SizedBox(height: 8),
                              const Text(
                                'Reminder delivery is temporarily unavailable.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: controller.loading ? null : () => _edit(),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add routine'),
                    ),
                    const SizedBox(height: 20),
                    if (controller.loading)
                      const Center(child: CircularProgressIndicator())
                    else if (controller.error != null)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            children: [
                              Text(controller.error!),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: controller.reload,
                                child: const Text('Try again'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (controller.routines.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Column(
                          children: [
                            Icon(
                              Icons.event_note_outlined,
                              color: HeatGuardColors.teal,
                              size: 42,
                            ),
                            SizedBox(height: 12),
                            Text(
                              'Start with your everyday.',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: HeatGuardColors.ink,
                                fontSize: 18,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Add an activity and choose its location, days, and reminder time.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    else
                      for (final routine in controller.routines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: routine.enabled
                                              ? HeatGuardColors.mint
                                              : HeatGuardColors.background,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          routine.time,
                                          style: const TextStyle(
                                            fontSize: 19,
                                            color: HeatGuardColors.teal,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          routine.title,
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: HeatGuardColors.ink,
                                          ),
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        tooltip: 'Routine options',
                                        onSelected: (action) => action == 'edit'
                                            ? _edit(routine)
                                            : _delete(routine),
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Edit'),
                                          ),
                                          PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '${routine.daysLabel} · ${routine.locationName}',
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${routine.timezone} · ${routine.leadMinutes == 0 ? 'Remind at activity time' : '${routine.leadMinutes} minutes before'}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 12,
                                    runSpacing: 6,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: _previewing != null
                                            ? null
                                            : () => _preview(routine),
                                        icon: const Icon(
                                          Icons.auto_awesome_outlined,
                                          size: 18,
                                        ),
                                        label: Text(
                                          _previewing == routine.id
                                              ? 'Preparing…'
                                              : 'Preview reminder',
                                        ),
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            routine.enabled
                                                ? 'Active'
                                                : 'Paused',
                                          ),
                                          Switch(
                                            value: routine.enabled,
                                            onChanged: (value) async {
                                              try {
                                                await controller.save(
                                                  routine.toForm(
                                                    enabled: value,
                                                  ),
                                                  id: routine.id,
                                                );
                                              } catch (error) {
                                                if (mounted) _error(error);
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    const SizedBox(height: 12),
                    const Text(
                      'Times follow each activity’s location. Weather can change; follow official advisories. Your reminder history stays private to your account.',
                      style: TextStyle(fontSize: 12, height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RoutineEditor extends StatefulWidget {
  const _RoutineEditor({
    required this.controller,
    required this.locations,
    this.routine,
  });
  final RoutinesController controller;
  final List<HeatLocation> locations;
  final HeatRoutine? routine;
  @override
  State<_RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends State<_RoutineEditor> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.routine?.title ?? '');
  late int? _location =
      widget.routine?.locationId ??
      (widget.locations.isEmpty ? null : widget.locations.first.id);
  late final Set<int> _days = {
    ...?widget.routine?.weekdays,
    if (widget.routine == null) ...[0, 1, 2, 3, 4],
  };
  late TimeOfDay _time = widget.routine == null
      ? const TimeOfDay(hour: 7, minute: 0)
      : TimeOfDay(
          hour: int.parse(widget.routine!.time.split(':')[0]),
          minute: int.parse(widget.routine!.time.split(':')[1]),
        );
  late int _lead = widget.routine?.leadMinutes ?? 15;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    if (_days.isEmpty) {
      setState(() => _error = 'Choose at least one day.');
      return;
    }
    final place = widget.locations.firstWhere((place) => place.id == _location);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final days = _days.toList()..sort();
      await widget.controller.save({
        'title': _title.text.trim(),
        'location_id': '${place.id}',
        'time':
            '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
        'weekdays': days.join(','),
        'timezone': place.timezone ?? 'UTC',
        'remind_before_minutes': '$_lead',
        'enabled': '${widget.routine?.enabled ?? true}',
      }, id: widget.routine?.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = widget.controller.message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final leadOptions = {0, 5, 10, 15, 30, 60, 120, _lead}.toList()..sort();
    final places = [...widget.locations];
    if (_location != null && !places.any((place) => place.id == _location)) {
      _location = null;
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.routine == null
                              ? 'Add routine'
                              : 'Edit routine',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close routine editor',
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFF874C22)),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    key: const ValueKey('routine-title'),
                    controller: _title,
                    enabled: !_saving,
                    maxLength: 80,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Activity name',
                      hintText: 'Go to school',
                      counterText: '',
                    ),
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? 'Enter your activity.'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue: _location,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Weather location',
                    ),
                    items: places
                        .map(
                          (place) => DropdownMenuItem(
                            value: place.id,
                            child: Text(
                              place.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _location = value),
                    validator: (value) =>
                        value == null ? 'Select a monitoring location.' : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _location == null
                        ? 'Choose a monitored location for your activity.'
                        : 'Time zone: ${places.firstWhere((place) => place.id == _location).timezone ?? 'UTC'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _saving
                        ? null
                        : () async {
                            final value = await showTimePicker(
                              context: context,
                              useRootNavigator: false,
                              initialTime: _time,
                            );
                            if (value != null && mounted) {
                              setState(() => _time = value);
                            }
                          },
                    icon: const Icon(Icons.schedule_rounded),
                    label: Text('Activity time: ${_time.format(context)}'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Repeat on',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: HeatGuardColors.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var day = 0; day < 7; day++)
                        FilterChip(
                          label: Text(
                            const [
                              'Mon',
                              'Tue',
                              'Wed',
                              'Thu',
                              'Fri',
                              'Sat',
                              'Sun',
                            ][day],
                          ),
                          selected: _days.contains(day),
                          onSelected: _saving
                              ? null
                              : (selected) => setState(() {
                                  if (selected) {
                                    _days.add(day);
                                  } else {
                                    _days.remove(day);
                                  }
                                }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<int>(
                    initialValue: _lead,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Remind me'),
                    items: leadOptions
                        .map(
                          (minutes) => DropdownMenuItem(
                            value: minutes,
                            child: Text(
                              minutes == 0
                                  ? 'At activity time'
                                  : '$minutes minutes before',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _lead = value ?? 15),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _saving || places.isEmpty ? null : _save,
                    icon: const Icon(Icons.check_rounded),
                    label: Text(_saving ? 'Saving…' : 'Save routine'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
