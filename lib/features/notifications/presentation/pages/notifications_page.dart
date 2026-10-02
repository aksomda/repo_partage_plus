import 'package:flutter/material.dart';

import '../../data/mock_notifications.dart';
import '../../domain/entities/app_notification.dart';
import '../widgets/notification_tile.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late List<AppNotification> _notifications;
  String _selectedFilter = 'Toutes';

  final List<String> _filters = [
    'Toutes',
    'Offres',
    'Réservations',
    'Impact',
  ];

  @override
  void initState() {
    super.initState();
    _notifications = List<AppNotification>.from(mockNotifications);
  }

  @override
  Widget build(BuildContext context) {
    final visibleNotifications = _filteredNotifications();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _markAllAsRead,
            child: const Text('Tout lire'),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilters(),
          Expanded(
            child: visibleNotifications.isEmpty
                ? _buildEmptyState()
                : ListView.separated(
                    itemCount: visibleNotifications.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final notification = visibleNotifications[index];

                      return NotificationTile(
                        notification: notification,
                        onTap: () => _markAsRead(notification.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 8,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = _filters[index];

          return ChoiceChip(
            label: Text(filter),
            selected: filter == _selectedFilter,
            onSelected: (_) {
              setState(() {
                _selectedFilter = filter;
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.notifications_none_outlined,
            size: 56,
            color: Colors.grey,
          ),
          SizedBox(height: 12),
          Text(
            'Aucune notification',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Les nouvelles alertes apparaîtront ici.',
          ),
        ],
      ),
    );
  }

  List<AppNotification> _filteredNotifications() {
    switch (_selectedFilter) {
      case 'Offres':
        return _notifications
            .where(
              (notification) =>
                  notification.type == AppNotificationType.offer ||
                  notification.type == AppNotificationType.expiration,
            )
            .toList();

      case 'Réservations':
        return _notifications
            .where(
              (notification) =>
                  notification.type == AppNotificationType.reservation ||
                  notification.type == AppNotificationType.reminder,
            )
            .toList();

      case 'Impact':
        return _notifications
            .where(
              (notification) =>
                  notification.type == AppNotificationType.impact,
            )
            .toList();

      default:
        return _notifications;
    }
  }

  void _markAsRead(String notificationId) {
    setState(() {
      _notifications = _notifications.map((notification) {
        if (notification.id == notificationId) {
          return notification.copyWith(isRead: true);
        }

        return notification;
      }).toList();
    });
  }

  void _markAllAsRead() {
    setState(() {
      _notifications = _notifications
          .map(
            (notification) => notification.copyWith(isRead: true),
          )
          .toList();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Toutes les notifications sont marquées comme lues.'),
      ),
    );
  }
}