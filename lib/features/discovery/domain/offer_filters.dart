import '../../offers/domain/entities/offer.dart';

class OfferFilters {
  final String? category;
  final OfferType? type;
  final double? maxDistanceKm;
  final bool onlyAvailable;
  final bool onlyUrgent;

  const OfferFilters({
    this.category,
    this.type,
    this.maxDistanceKm,
    this.onlyAvailable = true,
    this.onlyUrgent = false,
  });

  bool get hasActiveFilters {
    return category != null ||
        type != null ||
        maxDistanceKm != null ||
        onlyUrgent;
  }

  OfferFilters copyWith({
    String? category,
    bool clearCategory = false,
    OfferType? type,
    bool clearType = false,
    double? maxDistanceKm,
    bool clearMaxDistance = false,
    bool? onlyAvailable,
    bool? onlyUrgent,
  }) {
    return OfferFilters(
      category: clearCategory ? null : category ?? this.category,
      type: clearType ? null : type ?? this.type,
      maxDistanceKm: clearMaxDistance
          ? null
          : maxDistanceKm ?? this.maxDistanceKm,
      onlyAvailable: onlyAvailable ?? this.onlyAvailable,
      onlyUrgent: onlyUrgent ?? this.onlyUrgent,
    );
  }

  OfferFilters reset() {
    return const OfferFilters();
  }
}
