import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/impact/data/impact_repository.dart';
import 'package:repo_partage_plus/features/impact/domain/impact_csv.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Tableau de bord « Mon impact » : compteurs, indicateurs sociaux,
/// évolution sur 12 mois et répartition par catégorie. Lu sur l'appareil :
/// fonctionne hors ligne, actualisé en tirant vers le bas.
class ImpactScreen extends ConsumerStatefulWidget {
  const ImpactScreen({super.key});

  @override
  ConsumerState<ImpactScreen> createState() => _ImpactScreenState();
}

class _ImpactScreenState extends ConsumerState<ImpactScreen> {
  var _period = ImpactPeriod.all;

  @override
  void initState() {
    super.initState();
    // Chiffres récents dès l'ouverture, si le réseau le permet.
    Future.microtask(() => _refresh(quiet: true));
  }

  Future<void> _refresh({bool quiet = false}) async {
    final result = await ref.read(impactRepositoryProvider).refresh();
    if (!mounted || quiet) return;
    switch (result) {
      case ImpactRefresh.done:
        break;
      case ImpactRefresh.backup:
        showMessage(
          context,
          'Serveur momentanément indisponible : copie de secours affichée',
        );
      case ImpactRefresh.offline:
        showMessage(context, 'Hors ligne : derniers chiffres enregistrés');
    }
  }

  /// Copie le tableau d'impact au format CSV dans le presse-papiers.
  Future<void> _copyCsv() async {
    final csv = impactCsv(
      title: 'Mon impact sur Partage+',
      impact: ref.read(myImpactProvider) ?? const {},
      social: ref.read(myImpactSocialProvider) ?? const {},
      monthly: ref.read(myImpactMonthlyProvider),
      byCategory: ref.read(myImpactByCategoryProvider),
      socialLabels: const {
        'offers_shared': 'Offres partagées',
        'pickups_given': 'Retraits donnés',
        'people_helped': 'Personnes aidées',
        'associations_supported': 'Associations soutenues',
        'pickups_received': 'Retraits reçus',
        'donors_met': 'Donateurs rencontrés',
        'free_received': 'Dons gratuits reçus',
      },
    );
    await Clipboard.setData(ClipboardData(text: csv));
    if (mounted) {
      showMessage(context, 'Tableau copié : collez-le dans Excel ou Sheets');
    }
  }

  @override
  Widget build(BuildContext context) {
    final impact = ref.watch(myImpactProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon impact'),
        actions: [
          if (impact != null)
            IconButton(
              tooltip: 'Copier en CSV (Excel, Sheets)',
              icon: const Icon(Icons.table_view_outlined),
              onPressed: _copyCsv,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: impact == null
            ? const _EmptyState()
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _DataStatus(),
                          const SizedBox(height: 12),
                          _PeriodChips(
                            selected: _period,
                            onSelected: (period) =>
                                setState(() => _period = period),
                          ),
                          const SizedBox(height: 12),
                          _Counters(
                            impact: impactForPeriod(
                              _period,
                              total: impact,
                              monthly: ref.watch(myImpactMonthlyProvider),
                            ),
                          ),
                          const _SocialSection(),
                          const _SectionTitle(
                            'Répartition des produits sauvés',
                          ),
                          const _ChartCard(child: _CategoryChart()),
                          const _SectionTitle('Évolution sur 12 mois'),
                          const _ChartCard(child: _MonthlyChart()),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Période des compteurs (maquette) ; le serveur donne le total et les
/// 12 derniers mois.
enum ImpactPeriod {
  month('Ce mois'),
  year('Cette année'),
  all('Total');

  const ImpactPeriod(this.label);

  final String label;
}

/// Compteurs de la période : total, ou somme des mois concernés.
Json impactForPeriod(
  ImpactPeriod period, {
  required Json total,
  required List<Json> monthly,
  DateTime? now,
}) {
  if (period == ImpactPeriod.all) return total;
  final at = now ?? DateTime.now();
  final month = '${at.year}-${at.month.toString().padLeft(2, '0')}';
  final months = [
    for (final m in monthly)
      if (period == ImpactPeriod.month
          ? m['month'] == month
          : '${m['month']}'.startsWith('${at.year}-'))
        m,
  ];
  return {
    for (final key in const [
      'pickups',
      'items',
      'food_kg',
      'co2_kg',
      'meals',
      'estimated_pickups',
    ])
      key: months.fold<num>(0, (sum, m) => sum + (m[key] as num? ?? 0)),
  };
}

class _PeriodChips extends StatelessWidget {
  const _PeriodChips({required this.selected, required this.onSelected});

  final ImpactPeriod selected;
  final ValueChanged<ImpactPeriod> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final period in ImpactPeriod.values)
          ChoiceChip(
            label: Text(period.label),
            selected: period == selected,
            labelStyle: TextStyle(
              color: period == selected ? Colors.white : AppColors.text,
              fontWeight: FontWeight.w600,
            ),
            onSelected: (_) => onSelected(period),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    // Défilable, pour que « tirer pour actualiser » marche aussi ici.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: const [
        SizedBox(height: 48),
        Icon(Icons.eco_outlined, size: 56, color: AppColors.primary),
        SizedBox(height: 16),
        Text(
          'Pas encore de chiffres d’impact.\n'
          'Ils apparaîtront après votre premier don ou retrait. '
          'Tirez vers le bas pour actualiser.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// « Chiffres du 02/10 à 14:05 », hors ligne ou copie de secours.
class _DataStatus extends ConsumerWidget {
  const _DataStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (asOf, source) = ref.watch(myImpactAsOfProvider);
    final online = ref.watch(syncControllerProvider.select((s) => s.online));
    final parts = [
      if (asOf != null) '${_figuresOf(asOf)} à ${formatHour(asOf)}',
      if (!online) 'hors ligne',
      if (source == 'firestore') 'copie de secours',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(
          online ? Icons.update : Icons.cloud_off_outlined,
          size: 16,
          color: AppColors.textMuted,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            parts.join(' · '),
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// « Chiffres d'aujourd'hui », « Chiffres d'hier », « Chiffres du 02/10 ».
String _figuresOf(DateTime date) {
  final day = formatDay(date);
  return day.contains('/') ? 'Chiffres du $day' : 'Chiffres d’$day';
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 12),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Cartes en grille : 4 par rangée sur grand écran, 2 sur téléphone.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final columns = constraints.maxWidth >= 640 ? 4 : 2;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _Counters extends StatelessWidget {
  const _Counters({required this.impact});

  final Json impact;

  @override
  Widget build(BuildContext context) {
    final pickups = impact['pickups'] as num? ?? 0;
    final estimated = impact['estimated_pickups'] as num? ?? 0;
    return _CardGrid(
      children: [
        _StatCard(
          icon: Icons.shopping_bag_outlined,
          color: AppColors.primary,
          label: 'Produits sauvés',
          value: formatNumber(impact['items'] as num? ?? 0),
          detail: pickups <= 1
              ? '${formatNumber(pickups)} retrait'
              : '${formatNumber(pickups)} retraits',
        ),
        _StatCard(
          icon: Icons.delete_outline,
          color: AppColors.accent,
          label: 'Gaspillage évité',
          value: '${formatNumber(impact['food_kg'] as num?, decimals: 1)} kg',
          // Poids non indiqué par le publieur : estimé d'après l'unité.
          detail: estimated > 0
              ? 'dont ${formatNumber(estimated)} retrait${estimated > 1 ? 's' : ''} estimé${estimated > 1 ? 's' : ''}'
              : null,
        ),
        _StatCard(
          icon: Icons.eco_outlined,
          color: AppColors.leaf,
          label: 'CO₂ évité',
          value: '${formatNumber(impact['co2_kg'] as num?, decimals: 1)} kg',
        ),
        _StatCard(
          icon: Icons.restaurant_outlined,
          color: Color(0xFF2F6FB0),
          label: 'Repas équivalents',
          value: formatNumber(impact['meals'] as num?),
        ),
      ],
    );
  }
}

/// Indicateurs sociaux, selon ce que fait l'utilisateur : donner, recevoir,
/// ou les deux.
class _SocialSection extends ConsumerWidget {
  const _SocialSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final social = ref.watch(myImpactSocialProvider);
    if (social == null) return const SizedBox.shrink();
    final role = ref.watch(profileProvider)?['role'] as String?;
    num value(String key) => social[key] as num? ?? 0;

    final gives = role == 'donor' || value('offers_shared') > 0;
    final receives =
        role == 'beneficiary' ||
        role == 'association' ||
        value('pickups_received') > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Mon impact social'),
        _CardGrid(
          children: [
            if (gives) ...[
              _StatCard(
                icon: Icons.volunteer_activism_outlined,
                label: 'Offres partagées',
                value: formatNumber(value('offers_shared')),
              ),
              _StatCard(
                icon: Icons.people_outline,
                label: 'Personnes aidées',
                value: formatNumber(value('people_helped')),
              ),
              _StatCard(
                icon: Icons.diversity_3_outlined,
                label: 'Associations soutenues',
                value: formatNumber(value('associations_supported')),
              ),
            ],
            if (receives || !gives) ...[
              _StatCard(
                icon: Icons.inventory_2_outlined,
                label: 'Paniers récupérés',
                value: formatNumber(value('pickups_received')),
              ),
              _StatCard(
                icon: Icons.storefront_outlined,
                label: 'Donateurs rencontrés',
                value: formatNumber(value('donors_met')),
              ),
              _StatCard(
                icon: Icons.card_giftcard_outlined,
                label: 'Dons gratuits reçus',
                value: formatNumber(value('free_received')),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.color = AppColors.primary,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Pastille d'icône à gauche, chiffre et libellé à droite (maquette).
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
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
String _monthLabel(String month) {
  final index = int.tryParse(month.substring(5)) ?? 1;
  return _monthNames[(index - 1).clamp(0, 11)];
}

class _MonthlyChart extends ConsumerWidget {
  const _MonthlyChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final months = ref.watch(myImpactMonthlyProvider);
    if (months.isEmpty) {
      return const _ChartPlaceholder('Pas encore de données mensuelles.');
    }
    final values = [for (final m in months) (m['food_kg'] as num).toDouble()];
    final maxValue = values.fold<double>(0, (a, b) => a > b ? a : b);

    return SizedBox(
      height: 220,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxValue == 0 ? 1 : maxValue * 1.2,
          gridData: const FlGridData(drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => [
                for (final spot in spots)
                  LineTooltipItem(
                    '${_monthLabel(months[spot.x.toInt()]['month'] as String)}\n'
                    '${formatNumber(spot.y, decimals: 1)} kg',
                    const TextStyle(color: Colors.white, fontSize: 12),
                  ),
              ],
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
                interval: 1,
                reservedSize: 28,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= months.length || value != i) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _monthLabel(months[i]['month'] as String),
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
            rightTitles: const AxisTitles(),
            topTitles: const AxisTitles(),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < values.length; i++)
                  FlSpot(i.toDouble(), values[i]),
              ],
              preventCurveOverShooting: true,
              isCurved: true,
              color: AppColors.primary,
              barWidth: 3,
              belowBarData: BarAreaData(
                show: true,
                color: AppColors.primary.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChart extends ConsumerWidget {
  const _CategoryChart();

  /// Couleurs de l'application, puis variantes lisibles.
  static const _colors = [
    AppColors.primary,
    AppColors.accent,
    AppColors.leaf,
    Color(0xFF2F6FB0),
    Color(0xFF8E5BB5),
    Color(0xFF8D6E63),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(myImpactByCategoryProvider);
    if (categories.isEmpty) {
      return const _ChartPlaceholder('Pas encore de données par catégorie.');
    }
    double kg(Json c) => (c['food_kg'] as num).toDouble();
    final total = categories.fold<double>(0, (sum, c) => sum + kg(c));
    String share(Json c) =>
        total > 0 ? '${(kg(c) / total * 100).round()} %' : '0 %';

    final chart = SizedBox(
      height: 200,
      width: 200,
      child: PieChart(
        PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 52,
          sections: [
            for (var i = 0; i < categories.length; i++)
              PieChartSectionData(
                value: kg(categories[i]),
                color: _colors[i % _colors.length],
                title: share(categories[i]),
                radius: 40,
                titleStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < categories.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _colors[i % _colors.length],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    categories[i]['category_name'] as String,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${formatNumber(kg(categories[i]), decimals: 1)} kg'
                  ' · ${share(categories[i])}',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 520
          ? Row(
              children: [
                chart,
                const SizedBox(width: 24),
                Expanded(child: legend),
              ],
            )
          : Column(children: [chart, const SizedBox(height: 16), legend]),
    );
  }
}

class _ChartPlaceholder extends StatelessWidget {
  const _ChartPlaceholder(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Text(
          message,
          style: const TextStyle(color: AppColors.textMuted),
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
