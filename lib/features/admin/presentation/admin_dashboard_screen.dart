import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Tableau de bord de l'administrateur : activité de la plateforme, impact
/// global et tâches en attente. Lu dans la copie locale (hors ligne aussi).
class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(adminStatsProvider);
    final impact = asJson(ref.watch(adminImpactProvider)?['impact']) ?? {};
    final pendingAssociations = ref.watch(pendingAssociationsProvider).length;
    final waiting = ref.watch(waitingActionsProvider).length;
    num stat(String key) => stats[key] as num? ?? 0;

    final activity = [
      (Icons.people_outline, 'Utilisateurs', stat('users_total'), null),
      (
        Icons.inventory_2_outlined,
        'Offres en ligne',
        stat('offers_published'),
        null,
      ),
      (
        Icons.event_note_outlined,
        'Réservations en cours',
        stat('reservations_open'),
        null,
      ),
      (Icons.task_alt, 'Retraits effectués', stat('pickups_total'), null),
    ];
    final impactTiles = [
      (
        Icons.delete_outline,
        'Gaspillage évité',
        impact['food_kg'] as num? ?? 0,
        'kg',
      ),
      (Icons.eco_outlined, 'CO₂ évité', impact['co2_kg'] as num? ?? 0, 'kg'),
      (
        Icons.restaurant_outlined,
        'Repas équivalents',
        impact['meals'] as num? ?? 0,
        null,
      ),
    ];
    final tasks = [
      (
        Icons.verified_outlined,
        pendingAssociations == 0
            ? 'Aucune association à valider'
            : '$pendingAssociations association${pendingAssociations > 1 ? 's' : ''} à valider',
        AppRoutes.adminAssociations,
        pendingAssociations > 0,
      ),
      (
        Icons.block,
        '${formatNumber(stat('users_suspended'))} compte(s) désactivé(s)',
        AppRoutes.adminAccounts,
        false,
      ),
      (
        Icons.cloud_upload_outlined,
        waiting == 0
            ? 'Toutes les actions sont envoyées'
            : '$waiting action${waiting > 1 ? 's' : ''} en attente d’envoi',
        AppRoutes.adminManage,
        waiting > 0,
      ),
    ];

    return AdminShell(
      title: 'Tableau de bord',
      current: AppRoutes.adminDashboard,
      actions: const [AdminSyncButton()],
      builder: (context, wide) => RefreshIndicator(
        onRefresh: () => refreshAdminData(context, ref),
        child: stats.isEmpty
            ? const AdminEmptyMessage(
                icon: Icons.dashboard_outlined,
                text:
                    'Données non synchronisées : tirez vers le bas pour '
                    'actualiser.',
              )
            : ListView(
                padding: EdgeInsets.all(wide ? 24 : 16),
                children: [
                  const _SectionTitle('Activité'),
                  _TileGrid(
                    wide: wide,
                    children: [
                      for (final (icon, label, value, unit) in activity)
                        _StatTile(
                          icon: icon,
                          label: label,
                          value: value,
                          unit: unit,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(child: _SectionTitle('Impact global')),
                      TextButton(
                        onPressed: () => context.go(AppRoutes.adminImpact),
                        child: const Text('Détails ›'),
                      ),
                    ],
                  ),
                  _TileGrid(
                    wide: wide,
                    children: [
                      for (final (icon, label, value, unit) in impactTiles)
                        _StatTile(
                          icon: icon,
                          label: label,
                          value: value,
                          unit: unit,
                          decimals: unit == 'kg' ? 1 : 0,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const _SectionTitle('À traiter'),
                  for (final (icon, label, route, highlighted) in tasks)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          icon,
                          color: highlighted
                              ? AppColors.accent
                              : AppColors.textMuted,
                        ),
                        title: Text(
                          label,
                          style: TextStyle(
                            fontWeight: highlighted
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go(route),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.wide, required this.children});

  final bool wide;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = wide ? 4 : (constraints.maxWidth >= 520 ? 3 : 2);
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.decimals = 0,
  });

  final IconData icon;
  final String label;
  final num value;
  final String? unit;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(height: 8),
            Text(
              '${formatNumber(value, decimals: decimals)}'
              '${unit == null ? '' : ' $unit'}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            Text(
              label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
