import 'package:flutter/material.dart';

import '../../domain/entities/offer.dart';

class OfferCard extends StatelessWidget {
  final Offer offer;
  final VoidCallback onTap;
  final double? recommendationScore;
  final List<String> recommendationReasons;

  const OfferCard({
    super.key,
    required this.offer,
    required this.onTap,
    this.recommendationScore,
    this.recommendationReasons = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildImagePlaceholder(),
              const SizedBox(width: 12),
              Expanded(child: _buildOfferContent(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImagePlaceholder() {
    return Container(
      width: 86,
      height: 86,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.restaurant, color: Colors.green, size: 40),
    );
  }

  Widget _buildOfferContent(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                offer.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (recommendationScore != null) ...[
              const SizedBox(width: 8),
              _RecommendationScoreBadge(score: recommendationScore!),
            ],
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '${offer.merchantName} · ${_formatDistance(offer.distanceKm)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              offer.formattedPrice,
              style: TextStyle(
                color: Colors.green.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (offer.formattedOriginalPrice.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                offer.formattedOriginalPrice,
                style: const TextStyle(
                  color: Colors.grey,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        _buildRiskBadge(),
        if (recommendationReasons.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: recommendationReasons.take(2).map((reason) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.deepPurple.withAlpha(18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  reason,
                  style: const TextStyle(
                    color: Colors.deepPurple,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildRiskBadge() {
    late final String label;
    late final Color color;

    switch (offer.wasteRisk) {
      case WasteRisk.high:
        label = 'À sauver aujourd’hui';
        color = Colors.red;
      case WasteRisk.medium:
        label = 'Expire bientôt';
        color = Colors.orange;
      case WasteRisk.low:
        label = 'Disponible';
        color = Colors.green;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }

  String _formatDistance(double distanceKm) {
    if (distanceKm < 1) {
      return '${(distanceKm * 1000).round()} m';
    }

    return '${distanceKm.toStringAsFixed(1)} km';
  }
}

class _RecommendationScoreBadge extends StatelessWidget {
  final double score;

  const _RecommendationScoreBadge({required this.score});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withAlpha(24),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '${score.round()} / 100',
        style: const TextStyle(
          color: Colors.deepPurple,
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
      ),
    );
  }
}
