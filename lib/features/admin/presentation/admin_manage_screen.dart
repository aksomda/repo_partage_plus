import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';

/// Administration : accès aux réglages de la plateforme, avec leurs
/// compteurs lus dans la copie locale (disponibles hors ligne).
class AdminManageScreen extends ConsumerWidget {
  const AdminManageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(adminStatsProvider);
    final moderationOffers = ref.watch(moderationOffersProvider).length;
    final actors = ref.watch(actorsProvider).length;
    final factors = ref.watch(factorsProvider).length;
    final waiting = ref.watch(waitingActionsProvider).length;

    String count(num? value, String one, String many) => value == null
        ? 'Données non synchronisées'
        : '${value.toInt()} ${value == 1 ? one : many}';

    final sections = [
      (
        Icons.badge_outlined,
        'Acteurs',
        'Profils proposés à l’inscription et leurs droits',
        count(actors, 'acteur', 'acteurs'),
        AppRoutes.adminActors,
        false,
      ),
      (
        Icons.inventory_2_outlined,
        'Modération des offres',
        'Retirer une offre abusive',
        count(moderationOffers, 'offre visible', 'offres visibles'),
        AppRoutes.adminOffers,
        false,
      ),
      (
        Icons.category_outlined,
        'Catégories',
        'Catégories de produits proposées',
        count(stats['categories_total'] as num?, 'catégorie', 'catégories'),
        AppRoutes.adminCategories,
        false,
      ),
      (
        Icons.tune,
        'Facteurs d’impact',
        'CO₂ évité et repas par kg, par catégorie',
        count(factors, 'facteur', 'facteurs'),
        AppRoutes.adminFactors,
        false,
      ),
      (
        Icons.settings_outlined,
        'Paramètres',
        'Quotas des publications et réservations sans compte',
        'Plateforme',
        AppRoutes.adminSettings,
        false,
      ),
    ];

    return AdminShell(
      title: 'Administration',
      current: AppRoutes.adminManage,
      actions: const [AdminSyncButton()],
      builder: (context, wide) => RefreshIndicator(
        onRefresh: () => refreshAdminData(context, ref),
        child: ListView(
          padding: EdgeInsets.all(wide ? 24 : 16),
          children: [
            const Text(
              'Administration',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            if (waiting > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.cloud_upload_outlined,
                      size: 18,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$waiting modification${waiting > 1 ? 's' : ''} '
                        'en attente d’envoi : synchronisée${waiting > 1 ? 's' : ''} '
                        'au retour de la connexion.',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (icon, title, subtitle, counter, route, alert)
                    in sections)
                  SizedBox(
                    width: wide ? 340 : double.infinity,
                    child: _SectionCard(
                      icon: icon,
                      title: title,
                      subtitle: subtitle,
                      counter: counter,
                      alert: alert,
                      onTap: () => context.push(route),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.counter,
    required this.alert,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String counter;
  final bool alert;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primarySoft,
                foregroundColor: AppColors.primary,
                child: Icon(icon),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    AdminBadge(
                      counter,
                      alert ? AppColors.accentSoft : AppColors.primarySoft,
                      alert ? AppColors.accent : AppColors.primary,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
