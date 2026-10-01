import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/features/impact/data/impact_repository.dart';

class ImpactScreen extends ConsumerWidget {
  const ImpactScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final impact = ref.watch(myImpactProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mon impact')),
      body: impact == null
          ? const _ImpactEmptyState()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ImpactCounters(impact: impact),
                  const SizedBox(height: 24),
                  Text(
                    'Évolution mensuelle',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  const _MonthlyChart(),
                  const SizedBox(height: 24),
                  Text(
                    'Répartition des produits sauvés',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  const _CategoryPieChart(),
                ],
              ),
            ),
    );
  }
}

class _ImpactEmptyState extends StatelessWidget {
  const _ImpactEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          "Pas encore de données d'impact. Effectuez un retrait pour voir vos statistiques ici.",
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ImpactCounters extends StatelessWidget {
  const _ImpactCounters({required this.impact});

  final Map<String, dynamic> impact;

  @override
  Widget build(BuildContext context) {
    final pickups = impact['pickups'] ?? 0;
    final foodKg = impact['food_kg'] ?? 0;
    final co2Kg = impact['co2_kg'] ?? 0;
    final meals = impact['meals'] ?? 0;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.shopping_bag_outlined,
                label: 'Produits sauvés',
                value: '$pickups',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.delete_outline,
                label: 'Déchets évités',
                value: '$foodKg kg',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.eco_outlined,
                label: 'CO2 évité',
                value: '$co2Kg kg',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.restaurant_outlined,
                label: 'Repas équivalents',
                value: '$meals',
              ),
            ),
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
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _MonthlyChart extends ConsumerWidget {
  const _MonthlyChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monthlyAsync = ref.watch(myImpactMonthlyProvider);

    return monthlyAsync.when(
      loading: () => const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => SizedBox(
        height: 200,
        child: Center(child: Text('Erreur : $error')),
      ),
      data: (months) {
        if (months.isEmpty) {
          return const SizedBox(
            height: 200,
            child: Center(child: Text('Pas encore de données mensuelles.')),
          );
        }

        final spots = <FlSpot>[
          for (var i = 0; i < months.length; i++)
            FlSpot(i.toDouble(), (months[i]['food_kg'] as num).toDouble()),
        ];

        return SizedBox(
          height: 200,
          child: LineChart(
            LineChartData(
              gridData: const FlGridData(show: true),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 32),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= months.length) return const SizedBox.shrink();
                      final month = months[i]['month'] as String; // "2026-09"
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(month.substring(5), style: const TextStyle(fontSize: 11)),
                      );
                    },
                  ),
                ),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  color: Theme.of(context).colorScheme.primary,
                  barWidth: 3,
                  dotData: const FlDotData(show: true),
                  belowBarData: BarAreaData(
                    show: true,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CategoryPieChart extends ConsumerWidget {
  const _CategoryPieChart();

  static const _colors = [
    Colors.green,
    Colors.orange,
    Colors.blue,
    Colors.purple,
    Colors.teal,
    Colors.brown,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoriesAsync = ref.watch(myImpactByCategoryProvider);

    return categoriesAsync.when(
      loading: () => const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => SizedBox(
        height: 220,
        child: Center(child: Text('Erreur : $error')),
      ),
      data: (categories) {
        if (categories.isEmpty) {
          return const SizedBox(
            height: 220,
            child: Center(child: Text('Pas encore de données par catégorie.')),
          );
        }

        final total = categories.fold<double>(
          0,
          (sum, c) => sum + (c['food_kg'] as num).toDouble(),
        );

        return SizedBox(
          height: 220,
          child: Row(
            children: [
              Expanded(
                child: PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 36,
                    sections: [
                      for (var i = 0; i < categories.length; i++)
                        PieChartSectionData(
                          value: (categories[i]['food_kg'] as num).toDouble(),
                          color: _colors[i % _colors.length],
                          title: total > 0
                              ? '${(((categories[i]['food_kg'] as num) / total) * 100).round()}%'
                              : '0%',
                          radius: 60,
                          titleStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: categories.length,
                  itemBuilder: (context, i) => Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        color: _colors[i % _colors.length],
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          categories[i]['category_name'] as String,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}