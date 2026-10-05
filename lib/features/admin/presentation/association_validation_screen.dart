import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_forms.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';

/// Associations inscrites en attente de vérification : une association ne
/// peut réserver qu'une fois validée. Le refus exige un motif, envoyé à
/// l'association. Utilisable hors ligne (décisions mises en file).
class AssociationValidationScreen extends ConsumerWidget {
  const AssociationValidationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final associations = ref.watch(pendingAssociationsProvider);

    return AdminShell(
      title: 'Validation des associations',
      current: AppRoutes.adminManage,
      actions: const [AdminSyncButton()],
      builder: (context, wide) => RefreshIndicator(
        onRefresh: () => refreshAdminData(context, ref),
        child: associations.isEmpty
            ? const AdminEmptyMessage(
                icon: Icons.verified_outlined,
                text:
                    'Aucune association en attente.\nLes nouvelles '
                    'inscriptions d’associations s’afficheront ici.',
              )
            : ListView.separated(
                padding: EdgeInsets.all(wide ? 24 : 16),
                itemCount: associations.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) =>
                    _AssociationCard(association: associations[index]),
              ),
      ),
    );
  }
}

class _AssociationCard extends ConsumerStatefulWidget {
  const _AssociationCard({required this.association});

  final Json association;

  @override
  ConsumerState<_AssociationCard> createState() => _AssociationCardState();
}

class _AssociationCardState extends ConsumerState<_AssociationCard> {
  var _loading = false;

  Future<void> _review({required bool approve}) async {
    final name = widget.association['name'] as String? ?? 'l’association';
    String? reason;
    if (!approve) {
      reason = await askAdminReason(
        context,
        title: 'Refuser « $name » ?',
        action: 'Refuser',
        hint: 'Ex. : numéro d’enregistrement introuvable',
      );
      if (reason == null || !mounted) return;
    }

    setState(() => _loading = true);
    final result = await ref
        .read(adminRepositoryProvider)
        .reviewAssociation(
          widget.association,
          approve: approve,
          reason: reason,
        );
    if (!mounted) return;
    setState(() => _loading = false);
    showAdminResult(
      context,
      result,
      sent: approve ? '« $name » validée' : '« $name » refusée',
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.association;
    String? text(String key) {
      final value = a[key] as String?;
      return value == null || value.trim().isEmpty ? null : value;
    }

    final details = [
      (Icons.person_outline, 'Responsable', text('user_name')),
      (Icons.mail_outline, 'E-mail', text('email')),
      (Icons.phone_outlined, 'Téléphone', text('phone')),
      (Icons.numbers, 'N° d’enregistrement', text('registration_number')),
      (Icons.place_outlined, 'Adresse', text('address')),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: AppColors.primarySoft,
                  foregroundColor: AppColors.primary,
                  child: Icon(Icons.volunteer_activism_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a['name'] as String? ?? 'Association',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'Inscrite le ${formatAdminDate(a['created_at'])}',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final (icon, label, value) in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 16, color: AppColors.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$label : ',
                              style: const TextStyle(
                                color: AppColors.textMuted,
                              ),
                            ),
                            TextSpan(text: value ?? 'non renseigné'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  onPressed: _loading ? null : () => _review(approve: false),
                  icon: const Icon(Icons.close),
                  label: const Text('Refuser'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : () => _review(approve: true),
                  icon: _loading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Valider'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
