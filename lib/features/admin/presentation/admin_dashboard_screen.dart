import 'package:fl_chart/fl_chart.dart';
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
    final global = ref.watch(adminImpactProvider);
    final impact = asJson(global?['impact']) ?? {};
    final monthly = asJsonList(global?['monthly']);
    final byCategory = asJsonList(global?['by_category']);
    final waiting = ref.watch(waitingActionsProvider).length;
    num stat(String key) => stats[key] as num? ?? 0;

    const blue = Color(0xFF2F6FB0);
    final activity = [
      (
        Icons.people_outline,
        'Utilisateurs',
        stat('users_total'),
        null,
        AppColors.accent,
      ),
      (
        Icons.inventory_2_outlined,
        'Offres en ligne',
        stat('offers_published'),
        null,
        AppColors.primary,
      ),
      (
        Icons.event_note_outlined,
        'Réservations en cours',
        stat('reservations_open'),
        null,
        blue,
      ),
      (
        Icons.task_alt,
        'Retraits effectués',
        stat('pickups_total'),
        null,
        AppColors.leaf,
      ),
    ];
    final impactTiles = [
      (
        Icons.shopping_bag_outlined,
        'Produits sauvés',
        impact['items'] as num? ?? 0,
        null,
        AppColors.primary,
      ),
      (
        Icons.delete_outline,
        'Gaspillage évité',
        impact['food_kg'] as num? ?? 0,
        'kg',
        AppColors.accent,
      ),
      (
        Icons.eco_outlined,
        'CO₂ évité',
        impact['co2_kg'] as num? ?? 0,
        'kg',
        AppColors.leaf,
      ),
      (
        Icons.restaurant_outlined,
        'Repas équivalents',
        impact['meals'] as num? ?? 0,
        null,
        blue,
      ),
    ];
    final tasks = [
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
                      for (final (icon, label, value, unit, color) in activity)
                        _StatTile(
                          icon: icon,
                          label: label,
                          value: value,
                          unit: unit,
                          color: color,
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
                      for (final (icon, label, value, unit, color)
                          in impactTiles)
                        _StatTile(
                          icon: icon,
                          label: label,
                          value: value,
                          unit: unit,
                          color: color,
                          decimals: unit == 'kg' ? 1 : 0,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Graphiques côte à côte sur grand écran (maquette).
                  if (wide)
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 3,
                            child: _ChartCard(
                              title: 'Évolution de l’impact',
                              child: _ImpactTrendChart(months: monthly),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: _ChartCard(
                              title: 'Répartition par catégorie',
                              child: _CategoryDonut(categories: byCategory),
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    _ChartCard(
                      title: 'Évolution de l’impact',
                      child: _ImpactTrendChart(months: monthly),
                    ),
                    const SizedBox(height: 12),
                    _ChartCard(
                      title: 'Répartition par catégorie',
                      child: _CategoryDonut(categories: byCategory),
                    ),
                  ],
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
    this.color = AppColors.primary,
  });

  final IconData icon;
  final String label;
  final num value;
  final String? unit;
  final int decimals;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${formatNumber(value, decimals: decimals)}'
                      '${unit == null ? '' : ' $unit'}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
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

/// « 2026-09 » → « sept. ».
String _monthLabel(Object? month) {
  final index = int.tryParse('$month'.substring(5)) ?? 1;
  return _monthNames[(index - 1).clamp(0, 11)];
}

/// Couleurs des séries et des parts (charte, puis variantes lisibles).
const _chartColors = [
  AppColors.primary,
  AppColors.accent,
  AppColors.leaf,
  Color(0xFF2F6FB0),
  Color(0xFF8E5BB5),
  Color(0xFF8D6E63),
];

/// Carte titrée d'un graphique du tableau de bord.
class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});

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
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.label, {this.trailing});

  final Color color;
  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Évolution de l'impact sur 12 mois : produits sauvés et kg de
/// gaspillage évité, chacun rapporté à son maximum (échelles différentes).
class _ImpactTrendChart extends StatelessWidget {
  const _ImpactTrendChart({required this.months});

  final List<Json> months;

  @override
  Widget build(BuildContext context) {
    if (months.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(
          child: Text(
            'Pas encore de données mensuelles.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }
    final series = [
      ('Produits sauvés', 'items', ''),
      ('Gaspillage évité', 'food_kg', ' kg'),
    ];
    List<double> values(String key) => [
      for (final m in months) (m[key] as num? ?? 0).toDouble(),
    ];
    double maxOf(List<double> v) => v.fold<double>(0, (a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          children: [
            for (final (i, (label, _, _)) in series.indexed)
              _Legend(_chartColors[i], label),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: 1.1,
              gridData: const FlGridData(drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => [
                    for (final spot in spots)
                      LineTooltipItem(
                        '${_monthLabel(months[spot.x.toInt()]['month'])} : '
                        '${formatNumber(values(series[spot.barIndex].$2)[spot.x.toInt()], decimals: 1)}'
                        '${series[spot.barIndex].$3}',
                        const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                  ],
                ),
              ),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                topTitles: const AxisTitles(),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 1,
                    reservedSize: 26,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      // Un mois sur deux sur les écrans étroits.
                      if (i < 0 || i >= months.length || value != i) {
                        return const SizedBox.shrink();
                      }
                      if (meta.parentAxisSize < 400 && i.isOdd) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _monthLabel(months[i]['month']),
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineBarsData: [
                for (final (i, (_, key, _)) in series.indexed)
                  if (values(key) case final v)
                    LineChartBarData(
                      spots: [
                        for (var x = 0; x < v.length; x++)
                          FlSpot(
                            x.toDouble(),
                            maxOf(v) == 0 ? 0 : v[x] / maxOf(v),
                          ),
                      ],
                      isCurved: true,
                      preventCurveOverShooting: true,
                      color: _chartColors[i],
                      barWidth: 3,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: i == 0,
                        color: _chartColors[i].withValues(alpha: 0.10),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Répartition des produits sauvés par catégorie (anneau et légende).
class _CategoryDonut extends StatelessWidget {
  const _CategoryDonut({required this.categories});

  final List<Json> categories;

  @override
  Widget build(BuildContext context) {
    double kg(Json c) => (c['food_kg'] as num? ?? 0).toDouble();
    final total = categories.fold<double>(0, (sum, c) => sum + kg(c));
    if (categories.isEmpty || total == 0) {
      return const SizedBox(
        height: 160,
        child: Center(
          child: Text(
            'Pas encore de produits sauvés.',
            style: TextStyle(color: AppColors.textMuted),
          ),
        ),
      );
    }
    String share(Json c) => '${(kg(c) / total * 100).round()} %';

    return Row(
      children: [
        SizedBox(
          width: 140,
          height: 140,
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 38,
              sections: [
                for (final (i, c) in categories.indexed)
                  PieChartSectionData(
                    value: kg(c),
                    color: _chartColors[i % _chartColors.length],
                    radius: 26,
                    showTitle: false,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, c) in categories.indexed)
                _Legend(
                  _chartColors[i % _chartColors.length],
                  '${c['category_name']}',
                  trailing: share(c),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
