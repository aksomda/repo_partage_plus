import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/dev_menu.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Gestion des utilisateurs : l'administrateur désactive ou réactive un compte.
class AccountModerationScreen extends ConsumerStatefulWidget {
  const AccountModerationScreen({super.key});

  @override
  ConsumerState<AccountModerationScreen> createState() =>
      _AccountModerationScreenState();
}

class _AccountModerationScreenState
    extends ConsumerState<AccountModerationScreen> {
  static const _tabs = [
    (label: 'Tous', status: null),
    (label: 'Actifs', status: 'active'),
    (label: 'En attente', status: 'pending'),
    (label: 'Désactivés', status: 'suspended'),
  ];

  final _search = TextEditingController();
  Timer? _debounce;
  var _tab = 0;
  var _query = '';

  UserFilters get _filters => (status: _tabs[_tab].status, query: _query);

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      setState(() => _query = value.trim());
    });
  }

  Future<void> _toggle(Json user, bool activate) async {
    final name = user['name'] as String;
    final String? reason;
    if (activate) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Réactiver le compte ?'),
          content: Text('$name pourra de nouveau se connecter.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Réactiver'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      reason = null;
    } else {
      reason = await showDialog<String>(
        context: context,
        builder: (context) => _DeactivateDialog(name: name),
      );
      if (reason == null) return;
    }

    final result = await ref
        .read(adminRepositoryProvider)
        .setUserStatus(user['id'] as int, suspended: !activate, reason: reason);
    if (!mounted) return;

    switch (result) {
      case Sent():
        showMessage(
          context,
          activate ? 'Compte de $name réactivé' : 'Compte de $name désactivé',
        );
        ref.invalidate(adminUsersProvider);
      case Queued():
        showMessage(
          context,
          'Hors ligne : la modification sera envoyée plus tard',
        );
      case Rejected(:final message):
        showMessage(context, message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider(_filters));
    final pendingStatus = ref.watch(pendingUserStatusProvider);
    final location = GoRouterState.of(context).uri.toString();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Modération des comptes'),
        actions: [
          TextButton.icon(
            onPressed: () => context.push(AppRoutes.adminActors),
            icon: const Icon(Icons.badge_outlined),
            label: const Text('Acteurs'),
          ),
        ],
      ),
      drawer: DevMenu(currentLocation: location),
      body: Column(
        children: [
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _search,
                  onChanged: _onSearch,
                  decoration: const InputDecoration(
                    hintText: 'Rechercher un nom ou un e-mail…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (index, tab) in _tabs.indexed)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(tab.label),
                            selected: _tab == index,
                            onSelected: (_) => setState(() => _tab = index),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(adminUsersProvider(_filters).future),
              child: users.when(
                data: (list) => list.isEmpty
                    ? const _Message(
                        icon: Icons.person_search_outlined,
                        text: 'Aucun compte trouvé',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final user = list[index];
                          return _UserTile(
                            user: user,
                            pendingStatus: pendingStatus[user['id']],
                            onToggle: (activate) => _toggle(user, activate),
                          );
                        },
                      ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _Message(
                  icon: Icons.cloud_off,
                  text: '$error\nLa liste des comptes nécessite une connexion.',
                  onRetry: () => ref.invalidate(adminUsersProvider),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.user,
    required this.pendingStatus,
    required this.onToggle,
  });

  final Json user;

  /// Statut demandé hors ligne, pas encore envoyé.
  final String? pendingStatus;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final status = pendingStatus ?? user['status'] as String;
    final isAdmin = user['role'] == 'admin';
    final name = user['name'] as String;
    final actor = user['actor_label'] as String? ?? _roleLabel(user['role']);
    final reason = user['status_reason'] as String?;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.primarySoft,
              foregroundColor: AppColors.primary,
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    user['email'] as String,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _Badge(actor, AppColors.primarySoft, AppColors.primary),
                      _statusBadge(status),
                      if (pendingStatus != null)
                        const _Badge(
                          'En attente d’envoi',
                          AppColors.accentSoft,
                          AppColors.accent,
                        ),
                    ],
                  ),
                  if (status == 'suspended' && reason != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Motif : $reason',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!isAdmin && status != 'pending')
              Switch(
                value: status == 'active',
                onChanged: pendingStatus != null ? null : onToggle,
              ),
          ],
        ),
      ),
    );
  }

  static Widget _statusBadge(String status) => switch (status) {
    'active' => const _Badge('Actif', AppColors.primarySoft, AppColors.primary),
    'pending' => const _Badge(
      'Non activé',
      AppColors.accentSoft,
      AppColors.accent,
    ),
    _ => const _Badge('Désactivé', Color(0xFFFDE7E7), AppColors.danger),
  };

  static String _roleLabel(Object? role) => switch (role) {
    'admin' => 'Administrateur',
    'association' => 'Association',
    'donor' => 'Donateur',
    _ => 'Bénéficiaire',
  };
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.background, this.foreground);

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: background,
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.onRetry});

  final IconData icon;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    // ListView pour que « tirer pour actualiser » fonctionne aussi ici.
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(icon, size: 48, color: AppColors.textMuted),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textMuted),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton(
              onPressed: onRetry,
              child: const Text('Réessayer'),
            ),
          ),
        ],
      ],
    );
  }
}

class _DeactivateDialog extends StatefulWidget {
  const _DeactivateDialog({required this.name});

  final String name;

  @override
  State<_DeactivateDialog> createState() => _DeactivateDialogState();
}

class _DeactivateDialogState extends State<_DeactivateDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(_reason.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Désactiver le compte ?'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.name} ne pourra plus se connecter. '
              'Le motif lui sera communiqué.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _reason,
              autofocus: true,
              maxLength: 255,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Motif',
                hintText: 'Ex. : comportement abusif signalé',
              ),
              validator: requiredField('Motif obligatoire'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: _submit,
          child: const Text('Désactiver'),
        ),
      ],
    );
  }
}
