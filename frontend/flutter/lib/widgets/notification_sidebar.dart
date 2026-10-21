import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/routines_controller.dart';
import '../theme/heatguard_theme.dart';

class NotificationSidebar extends StatelessWidget {
  const NotificationSidebar({super.key, required this.controller});
  final RoutinesController controller;
  @override
  Widget build(BuildContext context) => Drawer(
    width: math.min(440, MediaQuery.sizeOf(context).width),
    backgroundColor: HeatGuardColors.background,
    child: SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 10, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Notifications',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh notifications',
                    onPressed: controller.reload,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: 'Close notifications',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  Text(
                    '${controller.unread} unread',
                    style: const TextStyle(color: HeatGuardColors.muted),
                  ),
                  TextButton(
                    onPressed: controller.unread == 0
                        ? null
                        : () async {
                            try {
                              await controller.markRead();
                            } catch (error) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(controller.message(error)),
                                  ),
                                );
                              }
                            }
                          },
                    child: const Text('Mark all read'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: controller.loading
                  ? const Center(child: CircularProgressIndicator())
                  : controller.error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(controller.error!),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: controller.reload,
                              child: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : controller.notices.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(30),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.notifications_none_rounded,
                              size: 46,
                              color: HeatGuardColors.teal,
                            ),
                            SizedBox(height: 16),
                            Text(
                              'A little heads-up, right here.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                color: HeatGuardColors.ink,
                              ),
                            ),
                            SizedBox(height: 10),
                            Text(
                              'Weather reminders will appear here when your routines are due.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: controller.notices.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final notice = controller.notices[index];
                        final received =
                            (notice.scheduledFor ?? notice.createdAt).toLocal();
                        final time = MaterialLocalizations.of(
                          context,
                        ).formatTimeOfDay(TimeOfDay.fromDateTime(received));
                        return Card(
                          color: notice.read
                              ? Colors.white
                              : HeatGuardColors.mint,
                          child: InkWell(
                            onTap: notice.read
                                ? null
                                : () async {
                                    try {
                                      await controller.markRead(id: notice.id);
                                    } catch (error) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              controller.message(error),
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        notice.read
                                            ? Icons.mark_email_read_outlined
                                            : Icons.mark_email_unread_outlined,
                                        color: HeatGuardColors.teal,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          notice.title,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: HeatGuardColors.ink,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    notice.body,
                                    style: const TextStyle(
                                      color: HeatGuardColors.ink,
                                      height: 1.55,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  Wrap(
                                    spacing: 12,
                                    runSpacing: 4,
                                    children: [
                                      Text(
                                        notice.aiGenerated
                                            ? 'AI-personalized'
                                            : notice.weather == null
                                            ? 'Weather unavailable'
                                            : 'Weather guidance',
                                        style: const TextStyle(
                                          color: HeatGuardColors.teal,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        '${received.day}/${received.month} · $time',
                                        style: const TextStyle(
                                          color: HeatGuardColors.muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                      if (!notice.read)
                                        const Text(
                                          'Tap to mark read',
                                          style: TextStyle(
                                            color: HeatGuardColors.muted,
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({
    super.key,
    required this.controller,
    required this.onPressed,
  });
  final RoutinesController controller;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (_, _) => IconButton(
      tooltip:
          'Notifications${controller.unread > 0 ? ', ${controller.unread} unread' : ''}',
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: controller.unread > 0,
        label: Text(controller.unread > 99 ? '99+' : '${controller.unread}'),
        child: const Icon(Icons.notifications_none_rounded),
      ),
    ),
  );
}
