import 'dart:math' as math;

import 'package:repo_partage_plus/core/location/geo.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';

/// Poids des critères du score local (somme = 1).
class ScoreWeights {
  const ScoreWeights({
    this.distance = 0.30,
    this.category = 0.25,
    this.urgency = 0.20,
    this.price = 0.15,
    this.publisher = 0.10,
  });

  final double distance;
  final double category;
  final double urgency;
  final double price;
  final double publisher;
}

/// Notes 0..1 de chaque critère, et total sur 100.
class ScoreBreakdown {
  const ScoreBreakdown({
    required this.distance,
    required this.category,
    required this.publisher,
    required this.urgency,
    required this.price,
    required this.total,
  });

  final double distance;
  final double category;
  final double publisher;
  final double urgency;
  final double price;

  /// Score final, 0 à 100.
  final double total;
}

/// Offre classée, avec le détail du score et les raisons affichées.
class RankedOffer {
  const RankedOffer({
    required this.offer,
    required this.score,
    required this.reasons,
    this.distanceKm,
    this.aiReason,
  });

  final Json offer;
  final ScoreBreakdown score;
  final double? distanceKm;

  /// Raisons lisibles du classement local (« À 800 m », « Gratuit »…).
  final List<String> reasons;

  /// Justification donnée par l'IA, si le classement a été affiné.
  final String? aiReason;

  int get id => offer['id'] as int;

  RankedOffer withAiReason(String? reason) => RankedOffer(
    offer: offer,
    score: score,
    reasons: reasons,
    distanceKm: distanceKm,
    aiReason: reason,
  );
}

/// Fiabilité par défaut selon le type de publieur (commerces et restaurants
/// ont des horaires et des stocks réguliers ; invité = sans compte).
const publisherBaseScore = {
  'commercant': 0.8,
  'restaurateur': 0.8,
  'particulier': 0.65,
  'invite': 0.5,
};

const publisherLabels = {
  'commercant': 'Commerçant',
  'restaurateur': 'Restaurateur',
  'particulier': 'Particulier',
  'invite': 'Sans compte',
};

/// Prix de référence (F CFA) quand l'utilisateur n'a pas fixé de maximum.
const referencePrice = 5000;

/// Premier niveau de la recommandation : classement calculé sur l'appareil,
/// disponible en permanence (hors ligne compris).
class LocalRanker {
  const LocalRanker({this.weights = const ScoreWeights()});

  final ScoreWeights weights;

  /// Classe les offres disponibles, de la plus pertinente à la moins.
  /// [excludeDonorId] : l'utilisateur ne se voit pas recommander ses offres.
  List<RankedOffer> rank(
    List<Json> offers, {
    required Place? origin,
    required RecoPreferences preferences,
    required UserHistory history,
    required DateTime now,
    int? excludeDonorId,
  }) {
    final ranked = <RankedOffer>[
      for (final offer in offers)
        if (isOfferAvailable(offer, now) &&
            (excludeDonorId == null || offer['donor_id'] != excludeDonorId))
          _score(offer, origin, preferences, history, now),
    ];
    ranked.sort((a, b) {
      final byScore = b.score.total.compareTo(a.score.total);
      if (byScore != 0) return byScore;
      // À score égal : la plus proche, puis la plus ancienne (id).
      final byDistance = (a.distanceKm ?? 0).compareTo(b.distanceKm ?? 0);
      return byDistance != 0 ? byDistance : a.id.compareTo(b.id);
    });
    return ranked;
  }

  RankedOffer _score(
    Json offer,
    Place? origin,
    RecoPreferences preferences,
    UserHistory history,
    DateTime now,
  ) {
    final reasons = <String>[];

    // Distance
    double? km;
    double distance;
    if (origin == null) {
      distance = 0.5;
    } else {
      km = haversineKm(
        origin.lat,
        origin.lng,
        (offer['latitude'] as num).toDouble(),
        (offer['longitude'] as num).toDouble(),
      );
      distance = (1 - km / preferences.maxDistanceKm).clamp(0.0, 1.0);
      if (distance >= 0.7) reasons.add('À ${formatDistance(km)}');
    }

    // Catégorie : préférences explicites, sinon historique.
    final categoryId = offer['category_id'];
    double category;
    if (preferences.categoryIds.isNotEmpty) {
      category = preferences.categoryIds.contains(categoryId) ? 1 : 0.1;
      if (category == 1) reasons.add('Catégorie recherchée');
    } else if (!history.isEmpty) {
      final affinity = history.categoryAffinity(categoryId);
      category = 0.3 + 0.7 * affinity;
      if (affinity >= 0.5) reasons.add('Selon vos habitudes');
    } else {
      category = 0.5;
    }

    // Type de publieur
    final type = offer['publisher_type'] as String? ?? 'invite';
    final base = publisherBaseScore[type] ?? 0.6;
    final double publisher;
    if (preferences.publisherTypes.isEmpty) {
      publisher = base;
    } else if (preferences.publisherTypes.contains(type)) {
      publisher = 1;
      reasons.add(publisherLabels[type] ?? type);
    } else {
      publisher = base * 0.4;
    }

    // Urgence : plus la date limite est proche, plus il faut éviter le gaspillage.
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime.parse(offer['expiry_date'] as String);
    final days = DateTime(
      expiry.year,
      expiry.month,
      expiry.day,
    ).difference(today).inDays;
    final urgency = switch (days) {
      <= 0 => 1.0,
      1 => 0.85,
      2 => 0.7,
      3 => 0.55,
      <= 6 => 0.4,
      _ => 0.2,
    };
    if (days <= 0) {
      reasons.add('Expire aujourd’hui');
    } else if (days == 1) {
      reasons.add('Expire demain');
    }

    // Prix par unité
    final amount = (offer['price'] as num? ?? 0).toDouble();
    final double price;
    if (amount == 0) {
      price = 1;
      reasons.add('Gratuit');
    } else {
      final limit = (preferences.maxPrice ?? referencePrice).toDouble();
      price = amount > limit ? 0 : 1 - 0.8 * amount / math.max(limit, 1);
      if (preferences.maxPrice != null && amount <= limit) {
        reasons.add('Dans votre budget');
      }
    }

    final total =
        100 *
        (weights.distance * distance +
            weights.category * category +
            weights.publisher * publisher +
            weights.urgency * urgency +
            weights.price * price);

    return RankedOffer(
      offer: km == null ? offer : {...offer, 'distance_km': km},
      distanceKm: km,
      reasons: reasons,
      score: ScoreBreakdown(
        distance: distance,
        category: category,
        publisher: publisher,
        urgency: urgency,
        price: price,
        total: double.parse(total.toStringAsFixed(1)),
      ),
    );
  }
}

/// Nombre d'offres présélectionnées envoyées à l'IA pour affinage.
const aiCandidateLimit = 100;
