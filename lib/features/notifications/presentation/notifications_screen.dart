import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';
import 'package:repo_partage_plus/features/notifications/presentation/widgets/chat_view.dart';

/// Notifications sous forme de mini chat, réservé aux comptes : fil de
/// l'utilisateur avec l'équipe Partage+, ou liste des conversations pour
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

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      drawer: AppMenu(currentLocation: location),
      body: const ChatView(),
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
