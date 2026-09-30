enum OfferType { free, discounted }

enum OfferStatus { available, reserved, collected, expired }

enum WasteRisk { low, medium, high }

class PickupSlot {
  final DateTime start;
  final DateTime end;
  final int availablePlaces;

  const PickupSlot({
    required this.start,
    required this.end,
    required this.availablePlaces,
  });

  bool get isFull => availablePlaces <= 0;
}

class Offer {
  final String id;
  final String title;
  final String description;
  final String category;

  final OfferType type;
  final OfferStatus status;
  final WasteRisk wasteRisk;

  final int price;
  final int originalPrice;
  final int remainingQuantity;

  final String merchantName;
  final String areaLabel;
  final double distanceKm;

  final DateTime expiresAt;
  final List<PickupSlot> pickupSlots;
  final List<String> allergens;

  const Offer({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.type,
    required this.status,
    required this.wasteRisk,
    required this.price,
    required this.originalPrice,
    required this.remainingQuantity,
    required this.merchantName,
    required this.areaLabel,
    required this.distanceKm,
    required this.expiresAt,
    required this.pickupSlots,
    this.allergens = const [],
  });

  bool get isFree {
    return type == OfferType.free || price == 0;
  }

  bool get isAvailable {
    return status == OfferStatus.available &&
        remainingQuantity > 0 &&
        !DateTime.now().isAfter(expiresAt);
  }

  String get formattedPrice {
    if (isFree) {
      return 'Gratuit';
    }

    return '$price FCFA';
  }

  String get formattedOriginalPrice {
    if (originalPrice <= price) {
      return '';
    }

    return '$originalPrice FCFA';
  }
}
