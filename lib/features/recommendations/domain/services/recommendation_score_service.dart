import '../../../offers/domain/entities/offer.dart';

class UserPreferences {
  final List<String> favoriteCategories;
  final List<OfferType> preferredTypes;
  final double maxDistanceKm;
  final int maxPrice;

  const UserPreferences({
    this.favoriteCategories = const [],
    this.preferredTypes = const [],
    this.maxDistanceKm = 3,
    this.maxPrice = 2000,
  });
}

class RecommendationResult {
  final Offer offer;
  final double score;
  final List<String> reasons;

  const RecommendationResult({
    required this.offer,
    required this.score,
    required this.reasons,
  });
}

class RecommendationScoreService {
  RecommendationResult evaluate({
    required Offer offer,
    required UserPreferences preferences,
  }) {
    final categoryScore = _categoryScore(
      offer: offer,
      preferences: preferences,
    );

    final typeScore = _typeScore(offer: offer, preferences: preferences);

    final distanceScore = _distanceScore(
      distanceKm: offer.distanceKm,
      maxDistanceKm: preferences.maxDistanceKm,
    );

    final priceScore = _priceScore(
      price: offer.price,
      maxPrice: preferences.maxPrice,
    );

    final urgencyScore = _urgencyScore(offer.wasteRisk);

    final score =
        (categoryScore * 0.30) +
        (typeScore * 0.15) +
        (distanceScore * 0.25) +
        (priceScore * 0.20) +
        (urgencyScore * 0.10);

    return RecommendationResult(
      offer: offer,
      score: score.clamp(0, 100),
      reasons: _buildReasons(offer: offer, preferences: preferences),
    );
  }

  List<RecommendationResult> rank({
    required List<Offer> offers,
    required UserPreferences preferences,
  }) {
    final results = offers
        .where((offer) => offer.isAvailable)
        .map((offer) => evaluate(offer: offer, preferences: preferences))
        .toList();

    results.sort((first, second) => second.score.compareTo(first.score));

    return results;
  }

  double _categoryScore({
    required Offer offer,
    required UserPreferences preferences,
  }) {
    if (preferences.favoriteCategories.contains(offer.category)) {
      return 100;
    }

    return 35;
  }

  double _typeScore({
    required Offer offer,
    required UserPreferences preferences,
  }) {
    if (preferences.preferredTypes.contains(offer.type)) {
      return 100;
    }

    return 50;
  }

  double _distanceScore({
    required double distanceKm,
    required double maxDistanceKm,
  }) {
    if (distanceKm <= 0.5) {
      return 100;
    }

    if (distanceKm <= maxDistanceKm) {
      return 85;
    }

    if (distanceKm <= maxDistanceKm * 2) {
      return 55;
    }

    return 25;
  }

  double _priceScore({required int price, required int maxPrice}) {
    if (price == 0) {
      return 100;
    }

    if (price <= maxPrice) {
      return 85;
    }

    return 35;
  }

  double _urgencyScore(WasteRisk risk) {
    switch (risk) {
      case WasteRisk.high:
        return 100;
      case WasteRisk.medium:
        return 65;
      case WasteRisk.low:
        return 35;
    }
  }

  List<String> _buildReasons({
    required Offer offer,
    required UserPreferences preferences,
  }) {
    final reasons = <String>[];

    if (preferences.favoriteCategories.contains(offer.category)) {
      reasons.add('Catégorie favorite');
    }

    if (offer.distanceKm <= preferences.maxDistanceKm) {
      reasons.add('Proche de vous');
    }

    if (offer.isFree) {
      reasons.add('Offre gratuite');
    } else if (offer.price <= preferences.maxPrice) {
      reasons.add('Dans votre budget');
    }

    if (offer.wasteRisk == WasteRisk.high) {
      reasons.add('À sauver rapidement');
    }

    if (reasons.isEmpty) {
      reasons.add('Offre disponible près de vous');
    }

    return reasons;
  }
}
