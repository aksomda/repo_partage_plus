import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Notifications, réservées aux comptes : celles de l'utilisateur par
/// onglet (et accès à ses messages), ou les conversations pour
/// l'administrateur.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.toString();

    // Écran déjà réservé par le routeur ; garde-fou si la session expire.
    if (!ref.watch(isLoggedInProvider)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        drawer: AppMenu(currentLocation: location),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: AppColors.textMuted,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Le mini chat est réservé aux personnes ayant un compte.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () =>
                      context.go(AppRoutes.loginThen(AppRoutes.notifications)),
                  child: const Text('Se connecter'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (ref.watch(profileProvider)?['role'] == 'admin') {
      return AdminShell(
        title: 'Notifications',
        current: AppRoutes.notifications,
        actions: const [AdminSyncButton()],
        builder: (context, wide) => const _Conversations(),
      );
    }

    return _UserNotifications(location: location);
  }
}

/// Notifications de l'utilisateur (maquette) : onglets Toutes,
/// Réservations, Infos, Conseils ; ses échanges avec l'équipe Partage+ sont
/// dans « Messages ».
class _UserNotifications extends ConsumerStatefulWidget {
  const _UserNotifications({required this.location});

  final String location;

  @override
  ConsumerState<_UserNotifications> createState() => _UserNotificationsState();
}

class _UserNotificationsState extends ConsumerState<_UserNotifications> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  /// Affichées : marquées lues (les messages, eux, à leur ouverture).
  void _markRead() {
    if (mounted) ref.read(chatRepositoryProvider).markRead(messages: false);
  }

  @override
  Widget build(BuildContext context) {
    // Copie locale lue après l'ouverture, ou nouvelles notifications.
    ref.listen(userNotificationsProvider, (_, _) => _markRead());
    final notifications = ref.watch(userNotificationsProvider);
    final unreadMessages = ref.watch(unreadMessagesCountProvider);
    final tabs = <(String, List<Json>)>[
      ('Toutes', notifications),
      for (final kind in NotificationKind.values)
        (
          kind.label,
          [
            for (final n in notifications)
              if (NotificationKind.of(n) == kind) n,
          ],
        ),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          actions: [
            IconButton(
              tooltip: 'Messages',
              icon: Badge.count(
                count: unreadMessages,
                isLabelVisible: unreadMessages > 0,
                child: const Icon(Icons.forum_outlined),
              ),
              onPressed: () => context.push(AppRoutes.messages),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            labelColor: Colors.white,
            unselectedLabelColor: AppColors.text,
            labelStyle: const TextStyle(fontWeight: FontWeight.w600),
            labelPadding: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            indicator: const ShapeDecoration(
              color: AppColors.primary,
              shape: StadiumBorder(),
            ),
            tabs: [
              for (final (label, items) in tabs)
                Tab(
                  height: 36,
                  text: label == 'Toutes' || items.isEmpty
                      ? label
                      : '$label (${items.length})',
                ),
            ],
          ),
        ),
        drawer: AppMenu(currentLocation: widget.location),
        body: RefreshIndicator(
          onRefresh: ref.read(syncControllerProvider.notifier).syncNow,
          child: TabBarView(
            children: [
              for (final (_, items) in tabs)
                _NotificationList(
                  notifications: items,
                  unreadMessages: unreadMessages,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationList extends StatelessWidget {
  const _NotificationList({
    required this.notifications,
    required this.unreadMessages,
  });

  final List<Json> notifications;
  final int unreadMessages;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Tirer pour actualiser, même sans notification.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _MessagesCard(unread: unreadMessages),
        const SizedBox(height: 12),
        if (notifications.isEmpty)
          const EmptyState(
            icon: Icons.notifications_none,
            title: 'Aucune notification',
            message: 'Réservations, retraits et conseils s’afficheront ici.',
          )
        else
          for (final notification in notifications) ...[
            _NotificationTile(notification: notification),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

/// Accès aux messages : équipe Partage+, publieurs et bénéficiaires.
class _MessagesCard extends StatelessWidget {
  const _MessagesCard({required this.unread});

  final int unread;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.primarySoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: ListTile(
        onTap: () => context.push(AppRoutes.messages),
        leading: const Icon(Icons.forum_outlined, color: AppColors.primary),
        title: const Text(
          'Messages',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          unread == 0
              ? 'Équipe Partage+, publieurs et bénéficiaires'
              : unread == 1
              ? '1 nouveau message'
              : '$unread nouveaux messages',
        ),
        trailing: unread > 0
            ? Badge(label: Text('$unread'))
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

/// Pictogramme et couleur d'une notification, selon son type.
(IconData, Color) _notificationStyle(Object? type) => switch (type) {
  'reservation_confirmed' ||
  'pickup_done' => (Icons.check_circle_outline, AppColors.primary),
  'reservation_created' ||
  'confirm_reminder' => (Icons.pending_actions, AppColors.accent),
  'pickup_reminder' || 'slot_changed' => (Icons.schedule, AppColors.accent),
  'reservation_cancelled' => (Icons.event_busy, AppColors.danger),
  'expiry_soon' => (Icons.hourglass_bottom, AppColors.danger),
  'search_match' => (Icons.shopping_basket_outlined, AppColors.primary),
  'association_review' => (Icons.verified_outlined, AppColors.primary),
  'offer_moderated' => (Icons.report_outlined, AppColors.danger),
  _ => (Icons.notifications_none, AppColors.primary),
};

/// « Aujourd'hui à 10:24 », « Hier à 16:45 », sinon « 12/10 à 08:12 ».
String _when(Object? value) {
  final date = DateTime.tryParse('${value ?? ''}')?.toLocal();
  if (date == null) return '';
  final day = formatDay(date);
  final hour =
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
  return '${day[0].toUpperCase()}${day.substring(1)} à $hour';
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification});

  final Json notification;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _notificationStyle(notification['type']);
    final link = notificationLink(notification);
    final unread = notification['read_at'] == null;
    final body = notification['body'] as String?;

    return Card(
      child: InkWell(
        onTap: link == null ? null : () => context.push(link),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${notification['title'] ?? 'Notification'}',
                      style: TextStyle(
                        fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                    if (body != null && body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      _when(notification['created_at']),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (unread)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 6, left: 4),
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              if (link != null)
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Conversations des utilisateurs avec l'administration.
class _Conversations extends ConsumerWidget {
  const _Conversations();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationsProvider);
    return RefreshIndicator(
      onRefresh: () => refreshAdminData(context, ref),
      child: conversations.isEmpty
          ? const AdminEmptyMessage(
              icon: Icons.forum_outlined,
              text:
                  'Aucune conversation.\nLes messages des utilisateurs '
                  's’afficheront ici.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: conversations.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final c = conversations[index];
                final last = c.last;
                final fromAdmin =
                    last['from_admin'] == 1 || last['from_admin'] == true;
                final body = last['body'] as String?;
                final preview = body != null && body.isNotEmpty
                    ? body
                    : '📷 Image';
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    onTap: () => context.push(AppRoutes.conversation(c.userId)),
                    leading: CircleAvatar(
                      backgroundColor: AppColors.primarySoft,
                      foregroundColor: AppColors.primary,
                      child: Text(
                        c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    title: Text(
                      c.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: c.unread > 0
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      '${fromAdmin ? 'Vous : ' : ''}$preview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatAdminDate(last['created_at']),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                        if (c.unread > 0) ...[
                          const SizedBox(height: 4),
                          Badge(label: Text('${c.unread}')),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
