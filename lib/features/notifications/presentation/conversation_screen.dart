import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';
import 'package:repo_partage_plus/features/notifications/presentation/widgets/chat_view.dart';

/// Conversation avec un utilisateur, ouverte par l'administrateur.
class ConversationScreen extends ConsumerWidget {
  const ConversationScreen({super.key, required this.userId});

  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = [
      for (final c in ref.watch(conversationsProvider))
        if (c.userId == userId) c.name,
      for (final u in ref.watch(adminUsersProvider))
        if (u['id'] == userId) u['name'] as String?,
    ].nonNulls.firstOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(name ?? 'Conversation')),
      body: ChatView(userId: userId),
    );
  }
}
