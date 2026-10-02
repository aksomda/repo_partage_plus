import 'package:flutter/material.dart';

import '../../domain/entities/app_notification.dart';

class NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback onTap;

  const NotificationTile({
    super.key,
    required this.notification,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _colorForType(notification.type);
    final icon = _iconForType(notification.type);

    return Material(
      color: notification.isRead
          ? Colors.transparent
          : color.withAlpha(18),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withAlpha(30),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title,
                            style: TextStyle(
                              fontWeight: notification.isRead
                                  ? FontWeight.w600
                                  : FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _timeLabel(notification.createdAt),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      notification.message,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (!notification.isRead) ...[
                const SizedBox(width: 8),
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(top: 7),
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForType(AppNotificationType type) {
    switch (type) {
      case AppNotificationType.offer:
        return Icons.storefront_outlined;
      case AppNotificationType.reservation:
        return Icons.check_circle_outline;
      case AppNotificationType.reminder:
        return Icons.alarm_outlined;
      case AppNotificationType.expiration:
        return Icons.warning_amber_rounded;
      case AppNotificationType.impact:
        return Icons.workspace_premium_outlined;
    }
  }

  Color _colorForType(AppNotificationType type) {
    switch (type) {
      case AppNotificationType.offer:
        return Colors.green;
      case AppNotificationType.reservation:
        return Colors.blue;
      case AppNotificationType.reminder:
        return Colors.deepPurple;
      case AppNotificationType.expiration:
        return Colors.orange;
      case AppNotificationType.impact:
        return Colors.amber.shade800;
    }
  }

  String _timeLabel(DateTime date) {
    final difference = DateTime.now().difference(date);

    if (difference.inMinutes < 1) {
      return 'Maintenant';
    }

    if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min';
    }

    if (difference.inHours < 24) {
      return '${difference.inHours} h';
    }

    if (difference.inDays == 1) {
      return 'Hier';
    }

    return '${difference.inDays} jours';
  }
}