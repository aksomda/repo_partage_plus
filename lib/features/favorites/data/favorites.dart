import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/location/geo.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/profile_repository.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';

/// Filtre de prix des offres.
enum PriceFilter {
  all('Tous les prix'),
  free('Gratuit'),
  paid('Prix réduit');

  const PriceFilter(this.label);

  final String label;

  static PriceFilter fromName(Object? name) =>
      values.where((value) => value.name == name).firstOrNull ?? all;

  bool accepts(Json offer) {
    final price = offer['price'] as num? ?? 0;
    return switch (this) {
      all => true,
      free => price == 0,
      paid => price > 0,
    };
  }
}

/// Offre dont la date limite tombe aujourd'hui ou demain.
bool expiresSoon(Json offer, DateTime now) {
  final expiry = DateTime.tryParse('${offer['expiry_date']}');
  if (expiry == null) return false;
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  return !DateTime(expiry.year, expiry.month, expiry.day).isAfter(tomorrow);
}

/// Texte cherché dans le titre, la description et la catégorie.
bool matchesText(Json offer, String text) {
  final query = text.trim().toLowerCase();
  if (query.isEmpty) return true;
  return [
    offer['title'],
    offer['description'],
    offer['category_name'],
  ].whereType<String>().any((value) => value.toLowerCase().contains(query));
}

/// Recherche enregistrée sous un nom : texte, catégorie, rayon, prix et
/// urgence.
class SavedSearch {
  const SavedSearch({
    required this.name,
    this.text = '',
    this.categoryId,
    this.radiusKm = double.infinity,
    this.price = PriceFilter.all,
    this.urgentOnly = false,
  });

  final String name;
  final String text;
  final int? categoryId;

  /// double.infinity : sans limite de distance.
  final double radiusKm;
  final PriceFilter price;

  /// Seulement les offres dont la date limite est aujourd'hui ou demain.
  final bool urgentOnly;

  /// L'offre répond à la recherche ; sans [origin], le rayon est ignoré.
  bool matches(Json offer, {Place? origin, required DateTime now}) {
    if (categoryId != null && offer['category_id'] != categoryId) return false;
    if (!price.accepts(offer)) return false;
    if (urgentOnly && !expiresSoon(offer, now)) return false;
    if (!matchesText(offer, text)) return false;
    if (origin == null) return true;
    final lat = offer['latitude'] as num?;
    final lng = offer['longitude'] as num?;
    if (lat == null || lng == null) return false;
    return haversineKm(
          origin.lat,
          origin.lng,
          lat.toDouble(),
          lng.toDouble(),
        ) <=
        radiusKm;
  }

  Map<String, Object?> toMap() => {
    'name': name,
    'text': text,
    'category_id': categoryId,
    // null : illimité (l'infini ne passe pas en JSON).
    'radius_km': radiusKm.isFinite ? radiusKm : null,
    'price': price.name,
    'urgent_only': urgentOnly,
  };

  static SavedSearch? fromMap(Object? value) {
    if (value is! Map || value['name'] is! String) return null;
    return SavedSearch(
      name: value['name'] as String,
      text: value['text'] as String? ?? '',
      categoryId: (value['category_id'] as num?)?.toInt(),
      radiusKm: (value['radius_km'] as num?)?.toDouble() ?? double.infinity,
      price: PriceFilter.fromName(value['price']),
      urgentOnly: value['urgent_only'] == true,
    );
  }
}

/// Nouvelles offres (absentes de [seen], pas publiées par l'utilisateur :
/// [ownIds]) qui répondent à une recherche enregistrée, chacune avec la
/// première recherche correspondante.
List<(Json, SavedSearch)> newOfferMatches({
  required List<Json> offers,
  required Set<int> seen,
  required List<SavedSearch> searches,
  required DateTime now,
  Place? origin,
  Set<int> ownIds = const {},
}) {
  return [
    for (final offer in offers)
      if (offer['id'] case final int id
          when !seen.contains(id) &&
              !ownIds.contains(id) &&
              isOfferAvailable(offer, now))
        if (searches
                .where(
                  (search) => search.matches(offer, origin: origin, now: now),
                )
                .firstOrNull
            case final search?)
          (offer, search),
  ];
}

/// Recherches proposées d'office, avec ou sans compte : un geste suffit
/// pour les lancer, sans rien enregistrer.
const suggestedSearches = [
  SavedSearch(
    name: 'Gratuit près de moi',
    radiusKm: 5,
    price: PriceFilter.free,
  ),
  SavedSearch(name: 'À sauver vite', urgentOnly: true),
  SavedSearch(name: 'À moins de 2 km', radiusKm: 2),
];

/// Offres et recherches favorites. Utilisables sans compte (gardées sur
/// l'appareil) ; avec un compte, recopiées dans ses préférences et donc
/// retrouvées sur ses autres appareils.
class Favorites {
  const Favorites({this.offerIds = const {}, this.searches = const []});

  final Set<int> offerIds;
  final List<SavedSearch> searches;

  bool get isEmpty => offerIds.isEmpty && searches.isEmpty;

  /// Réunion des deux : pour une même recherche (même nom), celle-ci gagne.
  Favorites mergedWith(Favorites other) => Favorites(
    offerIds: {...offerIds, ...other.offerIds},
    searches: [
      ...searches,
      for (final search in other.searches)
        if (!searches.any(
          (mine) => mine.name.toLowerCase() == search.name.toLowerCase(),
        ))
          search,
    ].take(maxSavedSearches).toList(),
  );

  Map<String, Object?> toMap() => {
    'offer_ids': offerIds.toList(),
    'searches': [for (final search in searches) search.toMap()],
  };

  static Favorites fromMap(Object? value) {
    if (value is! Map) return const Favorites();
    return Favorites(
      offerIds: {
        for (final id in value['offer_ids'] as List? ?? const [])
          if (id is num) id.toInt(),
      },
      searches: [
        for (final search in value['searches'] as List? ?? const [])
          ?SavedSearch.fromMap(search),
      ],
    );
  }
}

/// Nombre maximal de recherches enregistrées.
const maxSavedSearches = 10;

class FavoritesController extends Notifier<Favorites> {
  static const _key = 'favorites';

  /// Compte dont les favoris ont déjà été fusionnés avec ceux de l'appareil.
  static const _mergedKey = 'favorites_account';

  Timer? _upload;

  @override
  Favorites build() {
    Future.microtask(() async {
      final saved = await ref
          .read(localStoreProvider)
          .readSetting<Object?>(_key);
      if (saved != null) state = Favorites.fromMap(saved);
      await _syncAccount();
    });
    // Connexion, nouvel appareil, ou favoris changés sur un autre appareil.
    ref.listen<Json>(accountPreferencesProvider, (_, _) => _syncAccount());
    // Déconnexion : la base locale est vidée, les favoris aussi.
    ref.listen<String?>(authTokenProvider, (_, token) {
      if (token == null) state = const Favorites();
    });
    ref.onDispose(() => _upload?.cancel());
    return const Favorites();
  }

  /// Première fois avec ce compte sur l'appareil : favoris de l'appareil
  /// (faits sans compte) et du compte réunis, rien n'est perdu. Ensuite, le
  /// compte fait foi (modifications faites sur un autre appareil).
  Future<void> _syncAccount() async {
    final accountId = ref.read(profileProvider)?['id'];
    if (ref.read(authTokenProvider) == null || accountId == null) return;
    // Modification locale pas encore envoyée : ne pas l'écraser.
    if (_upload?.isActive ?? false) return;

    final store = ref.read(localStoreProvider);
    final account = Favorites.fromMap(
      ref.read(accountPreferencesProvider)['favorites'],
    );
    if (await store.readSetting<Object?>(_mergedKey) != accountId) {
      final merged = state.mergedWith(account);
      await store.saveSetting(_mergedKey, accountId);
      state = merged;
      await store.saveSetting(_key, merged.toMap());
      if (merged.toMap().toString() != account.toMap().toString()) {
        _scheduleUpload();
      }
      return;
    }
    if (ref.read(accountPreferencesProvider).containsKey('favorites')) {
      state = account;
      await store.saveSetting(_key, account.toMap());
    }
  }

  bool isFavorite(Object? offerId) => state.offerIds.contains(offerId);

  Future<void> toggleOffer(int offerId) {
    final ids = {...state.offerIds};
    if (!ids.remove(offerId)) ids.add(offerId);
    return _save(Favorites(offerIds: ids, searches: state.searches));
  }

  /// Enregistre (ou remplace, même nom) une recherche.
  Future<void> saveSearch(SavedSearch search) {
    final searches = [
      search,
      for (final existing in state.searches)
        if (existing.name.toLowerCase() != search.name.toLowerCase()) existing,
    ].take(maxSavedSearches).toList();
    return _save(Favorites(offerIds: state.offerIds, searches: searches));
  }

  Future<void> removeSearch(String name) {
    return _save(
      Favorites(
        offerIds: state.offerIds,
        searches: [
          for (final search in state.searches)
            if (search.name != name) search,
        ],
      ),
    );
  }

  Future<void> _save(Favorites favorites) async {
    state = favorites;
    await ref.read(localStoreProvider).saveSetting(_key, favorites.toMap());
    if (ref.read(authTokenProvider) == null) return;
    _scheduleUpload();
  }

  /// Plusieurs changements d'affilée : un seul envoi, après le dernier.
  void _scheduleUpload() {
    _upload?.cancel();
    _upload = Timer(const Duration(seconds: 2), () {
      ref.read(profileRepositoryProvider).savePreferences({
        'favorites': state.toMap(),
      });
    });
  }
}

final favoritesProvider = NotifierProvider<FavoritesController, Favorites>(
  FavoritesController.new,
);
