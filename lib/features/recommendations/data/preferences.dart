import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/reservations/data/reservations_repository.dart';

/// Préférences de recommandation, gardées sur l'appareil.
class RecoPreferences {
  const RecoPreferences({
    this.text = '',
    this.categoryIds = const {},
    this.publisherTypes = const {},
    this.maxPrice,
    this.maxDistanceKm = 10,
  });

  /// Souhaits en texte libre ou dictés (« légumes pour ce soir… »).
  final String text;
  final Set<int> categoryIds;

  /// Codes : particulier, commercant, restaurateur, invite.
  final Set<String> publisherTypes;

  /// Prix maximum par unité en F CFA (null : pas de limite).
  final int? maxPrice;
  final double maxDistanceKm;

  RecoPreferences copyWith({
    String? text,
    Set<int>? categoryIds,
    Set<String>? publisherTypes,
    int? Function()? maxPrice,
    double? maxDistanceKm,
  }) {
    return RecoPreferences(
      text: text ?? this.text,
      categoryIds: categoryIds ?? this.categoryIds,
      publisherTypes: publisherTypes ?? this.publisherTypes,
      maxPrice: maxPrice == null ? this.maxPrice : maxPrice(),
      maxDistanceKm: maxDistanceKm ?? this.maxDistanceKm,
    );
  }

  Map<String, Object?> toMap() => {
    'text': text,
    'category_ids': categoryIds.toList(),
    'publisher_types': publisherTypes.toList(),
    'max_price': maxPrice,
    'max_distance_km': maxDistanceKm,
  };

  static RecoPreferences fromMap(Object? value) {
    if (value is! Map) return const RecoPreferences();
    return RecoPreferences(
      text: value['text'] as String? ?? '',
      categoryIds: {
        for (final id in value['category_ids'] as List? ?? const [])
          if (id is int) id,
      },
      publisherTypes: {
        for (final type in value['publisher_types'] as List? ?? const [])
          if (type is String) type,
      },
      maxPrice: value['max_price'] as int?,
      maxDistanceKm: (value['max_distance_km'] as num?)?.toDouble() ?? 10,
    );
  }
}

class RecoPreferencesController extends Notifier<RecoPreferences> {
  static const _key = 'reco_preferences';

  @override
  RecoPreferences build() {
    Future.microtask(() async {
      final saved = await ref
          .read(localStoreProvider)
          .readSetting<Object?>(_key);
      if (saved != null) state = RecoPreferences.fromMap(saved);
    });
    return const RecoPreferences();
  }

  Future<void> update(RecoPreferences preferences) async {
    state = preferences;
    await ref.read(localStoreProvider).saveSetting(_key, preferences.toMap());
  }
}

final recoPreferencesProvider =
    NotifierProvider<RecoPreferencesController, RecoPreferences>(
      RecoPreferencesController.new,
    );

// ---------- Historique d'interactions ----------

/// Nombre maximal d'interactions gardées (les plus récentes).
const maxInteractions = 100;

/// Enregistre qu'une offre a été consultée (sur l'appareil uniquement).
Future<void> recordOfferView(LocalStore store, Json offer) async {
  final list = List<Object?>.from(
    await store.readSetting<List<Object?>>('interactions') ?? const [],
  );
  list.insert(0, {
    'kind': 'view',
    'offer_id': offer['id'],
    'title': offer['title'],
    'category_id': offer['category_id'],
    'category_name': offer['category_name'],
    'publisher_type': offer['publisher_type'],
    'at': DateTime.now().toUtc().toIso8601String(),
  });
  await store.saveSetting('interactions', list.take(maxInteractions).toList());
}

/// Résumé de l'historique : consultations et réservations de l'utilisateur.
class UserHistory {
  const UserHistory({
    this.categoryCounts = const {},
    this.publisherCounts = const {},
    this.recentTitles = const [],
    this.reservedTitles = const [],
  });

  /// Poids par catégorie (une réservation compte plus qu'une consultation).
  final Map<int, double> categoryCounts;
  final Map<String, double> publisherCounts;
  final List<String> recentTitles;
  final List<String> reservedTitles;

  bool get isEmpty => categoryCounts.isEmpty && reservedTitles.isEmpty;

  /// Affinité 0..1 pour une catégorie (1 = la plus consultée / réservée).
  double categoryAffinity(Object? categoryId) {
    if (categoryCounts.isEmpty || categoryId is! int) return 0;
    final max = categoryCounts.values.reduce((a, b) => a > b ? a : b);
    return (categoryCounts[categoryId] ?? 0) / max;
  }
}

/// Poids d'une réservation par rapport à une simple consultation.
const reservationWeight = 3.0;

UserHistory buildHistory(List<Json> interactions, List<Json> reservations) {
  final categories = <int, double>{};
  final publishers = <String, double>{};
  for (final item in interactions) {
    if (item['category_id'] case final int id) {
      categories[id] = (categories[id] ?? 0) + 1;
    }
    if (item['publisher_type'] case final String type) {
      publishers[type] = (publishers[type] ?? 0) + 1;
    }
  }
  for (final reservation in reservations) {
    if (reservation['category_id'] case final int id) {
      categories[id] = (categories[id] ?? 0) + reservationWeight;
    }
  }
  return UserHistory(
    categoryCounts: categories,
    publisherCounts: publishers,
    recentTitles: [
      for (final item in interactions.take(15))
        if (item['title'] case final String title) title,
    ],
    reservedTitles: [
      for (final reservation in reservations.take(15))
        if (reservation['offer_title'] case final String title) title,
    ],
  );
}

final _interactionsProvider = StreamProvider<List<Json>>(
  (ref) => ref
      .watch(localStoreProvider)
      .watchSetting('interactions')
      .map(asJsonList),
);

/// Historique de l'utilisateur : consultations sur l'appareil, réservations
/// du compte et réservations faites sans compte.
final userHistoryProvider = Provider<UserHistory>((ref) {
  final loggedIn = ref.watch(authTokenProvider) != null;
  return buildHistory(ref.watch(_interactionsProvider).value ?? const [], [
    if (loggedIn) ...ref.watch(myReservationsProvider),
    ...ref.watch(guestReservationsProvider).value ?? const [],
  ]);
});
