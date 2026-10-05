import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';

/// Notifications reçues, marquées lues localement dès que l'utilisateur
/// les ouvre, même hors ligne.
final notificationsProvider = Provider<List<Json>>((ref) {
  final actions = ref.watch(waitingActionsProvider);
  final readAll = actions.any((a) => a.kind == 'notification.read_all');
  final readIds = {
    for (final action in actions)
      if (action.kind == 'notification.read') action.targetId,
  };

  return [
    for (final notification in ref.watch(snapshotListProvider('notifications')))
      if (readAll || readIds.contains(notification['id']))
        {...notification, 'read_at': notification['read_at'] ?? 'local'}
      else
        notification,
  ];
});

final unreadCountProvider = Provider<int>(
  (ref) => ref
      .watch(notificationsProvider)
      .where((n) => n['read_at'] == null)
      .length,
);

/// Actions refusées par le serveur, à montrer à l'utilisateur.
final rejectedActionsProvider = Provider<List<PendingAction>>((ref) {
  final actions = ref.watch(pendingActionsProvider).value ?? const [];
  return actions.where((action) => action.isRejected).toList();
});

class NotificationsRepository {
  NotificationsRepository(this._sync, this._clearRejected);

  final SyncController _sync;
  final Future<void> Function() _clearRejected;

  Future<SubmitResult> markRead(int notificationId) {
    return _sync.submit(
      PendingAction(
        kind: 'notification.read',
        method: 'PATCH',
        path: ApiEndpoints.readNotification(notificationId),
        targetId: notificationId,
        label: 'Notification lue',
      ),
    );
  }

  Future<SubmitResult> markAllRead() {
    return _sync.submit(
      PendingAction(
        kind: 'notification.read_all',
        method: 'PATCH',
        path: ApiEndpoints.readAllNotifications,
        label: 'Notifications lues',
      ),
    );
  }

  Future<void> dismissRejected() => _clearRejected();
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => NotificationsRepository(
    ref.read(syncControllerProvider.notifier),
    ref.read(outboxProvider).clearRejected,
  ),
);
