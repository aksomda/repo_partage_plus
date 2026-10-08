import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/impact/domain/impact_csv.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Impact de toute la plateforme : totaux, évolution sur 12 mois et
/// répartition par catégorie. Copie locale : consultable hors ligne.
class AdminImpactScreen extends ConsumerWidget {
  const AdminImpactScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminImpactProvider);
    final impact = asJson(data?['impact']) ?? const {};
    final months = asJsonList(data?['monthly']);
    final categories = asJsonList(data?['by_category']);
    final social = asJson(data?['social']) ?? const {};

    return AdminShell(
      title: 'Impact de la plateforme',
      current: AppRoutes.adminImpact,
      actions: const [AdminSyncButton()],
      builder: (context, wide) => RefreshIndicator(
        onRefresh: () => refreshAdminData(context, ref),
        child: data == null
            ? const AdminEmptyMessage(
                icon: Icons.eco_outlined,
                text:
                    'Aucune copie locale de l’impact.\n'
                    'Connectez-vous à Internet pour la télécharger.',
              )
            : ListView(
                padding: EdgeInsets.all(wide ? 24 : 16),
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Impact de la plateforme',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copier en CSV (Excel, Sheets)',
                        icon: const Icon(Icons.table_view_outlined),
                        onPressed: () => _copyCsv(context, data),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => context.push(AppRoutes.adminFactors),
                        icon: const Icon(Icons.tune, size: 18),
                        label: const Text('Facteurs d’impact'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Calculé le ${formatAdminDate(data['as_of'], time: true)}',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Stat(
                        Icons.shopping_basket_outlined,
                        'Retraits',
                        formatNumber(impact['pickups'] as num?),
                      ),
                      _Stat(
                        Icons.scale_outlined,
                        'Nourriture sauvée',
                        '${formatNumber(impact['food_kg'] as num?, decimals: 1)} kg',
                      ),
                      _Stat(
                        Icons.cloud_outlined,
                        'CO₂ évité',
                        '${formatNumber(impact['co2_kg'] as num?, decimals: 1)} kg',
                      ),
                      _Stat(
                        Icons.restaurant_outlined,
                        'Repas',
                        formatNumber(impact['meals'] as num?),
                      ),
                      _Stat(
                        Icons.people_outline,
                        'Utilisateurs actifs',
                        formatNumber(impact['users'] as num?),
                      ),
                    ],
                  ),
                  if (social.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text(
                      'Indicateurs sociaux',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final (key, icon) in _socialIcons)
                          if (social[key] != null)
                            _Stat(
                              icon,
                              adminSocialLabels[key]!,
                              key.endsWith('_share') || key.endsWith('_rate')
                                  ? '${formatNumber(social[key] as num?)} %'
                                  : formatNumber(social[key] as num?),
                            ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  _Section(
                    title: 'Nourriture sauvée par mois (kg)',
                    child: _MonthlyBars(months: months),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Par catégorie',
                    child: _Categories(categories: categories),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Libellés des indicateurs sociaux de la plateforme.
const adminSocialLabels = {
  'people_helped': 'Personnes aidées',
  'associations_supported': 'Associations soutenues',
  'active_donors': 'Donateurs actifs',
  'offers_shared': 'Offres partagées',
  'free_share': 'Retraits gratuits',
  'completion_rate': 'Offres écoulées',
};

const _socialIcons = [
  ('people_helped', Icons.volunteer_activism_outlined),
  ('associations_supported', Icons.groups_outlined),
  ('active_donors', Icons.storefront_outlined),
  ('offers_shared', Icons.inventory_2_outlined),
  ('free_share', Icons.card_giftcard_outlined),
  ('completion_rate', Icons.task_alt),
];

/// Copie le tableau d'impact au format CSV dans le presse-papiers.
Future<void> _copyCsv(BuildContext context, Json data) async {
  final csv = impactCsv(
    title:
        'Impact de la plateforme Partage+ (${formatAdminDate(data['as_of'])})',
    impact: asJson(data['impact']) ?? const {},
    social: asJson(data['social']) ?? const {},
    monthly: asJsonList(data['monthly']),
    byCategory: asJsonList(data['by_category']),
    socialLabels: adminSocialLabels,
  );
  await Clipboard.setData(ClipboardData(text: csv));
  if (context.mounted) {
    showMessage(context, 'Tableau copié : collez-le dans Excel ou Sheets');
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.primary),
              const SizedBox(height: 8),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

const _monthNames = [
  'janv.',
  'févr.',
  'mars',
  'avr.',
  'mai',
  'juin',
  'juil.',
  'août',
  'sept.',
  'oct.',
  'nov.',
  'déc.',
];

/// « 2026-10 » → « oct. ».
String _monthLabel(String month) {
  final index = int.tryParse(month.split('-').last) ?? 1;
  return _monthNames[(index - 1).clamp(0, 11)];
}

class _MonthlyBars extends StatelessWidget {
  const _MonthlyBars({required this.months});

  final List<Json> months;

  @override
  Widget build(BuildContext context) {
    final values = [
      for (final m in months) (m['food_kg'] as num? ?? 0).toDouble(),
    ];
    if (values.every((value) => value == 0)) {
      return const Text(
        'Pas encore de retrait sur les 12 derniers mois.',
        style: TextStyle(color: AppColors.textMuted),
      );
    }
    final maxValue = values.reduce((a, b) => a > b ? a : b);

    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          maxY: maxValue * 1.2,
          gridData: const FlGridData(drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                '${_monthLabel(months[group.x]['month'] as String)}\n'
                '${formatNumber(rod.toY, decimals: 1)} kg',
                const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) => Text(
                  formatNumber(value, decimals: 1),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (value, meta) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _monthLabel(months[value.toInt()]['month'] as String),
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ),
            rightTitles: const AxisTitles(),
            topTitles: const AxisTitles(),
          ),
          barGroups: [
            for (final (i, value) in values.indexed)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: value,
                    width: 14,
                    color: AppColors.primary,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
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

class _Categories extends StatelessWidget {
  const _Categories({required this.categories});

  final List<Json> categories;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return const Text(
        'Pas encore de retrait.',
        style: TextStyle(color: AppColors.textMuted),
      );
    }
    final total = categories.fold<double>(
      0,
      (sum, c) => sum + (c['food_kg'] as num? ?? 0).toDouble(),
    );
    return Column(
      children: [
        for (final c in categories)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c['category_name'] as String? ?? '—',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${formatNumber(c['food_kg'] as num?, decimals: 1)} kg · '
                      '${formatNumber(c['co2_kg'] as num?, decimals: 1)} kg CO₂',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: total == 0
                      ? 0
                      : (c['food_kg'] as num? ?? 0).toDouble() / total,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                  backgroundColor: AppColors.primarySoft,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
