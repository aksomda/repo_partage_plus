import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/profile_repository.dart';

/// Recherche enregistrée sous un nom : texte, catégorie et rayon.
class SavedSearch {
  const SavedSearch({
    required this.name,
    this.text = '',
    this.categoryId,
    this.radiusKm = 10,
  });

  final String name;
  final String text;
  final int? categoryId;
  final double radiusKm;

  Map<String, Object?> toMap() => {
    'name': name,
    'text': text,
    'category_id': categoryId,
    'radius_km': radiusKm,
  };

  static SavedSearch? fromMap(Object? value) {
    if (value is! Map || value['name'] is! String) return null;
    return SavedSearch(
      name: value['name'] as String,
      text: value['text'] as String? ?? '',
      categoryId: (value['category_id'] as num?)?.toInt(),
      radiusKm: (value['radius_km'] as num?)?.toDouble() ?? 10,
    );
  }
}

/// Offres et recherches favorites. Utilisables sans compte (gardées sur
/// l'appareil) ; avec un compte, recopiées dans ses préférences et donc
/// retrouvées sur ses autres appareils.
class Favorites {
  const Favorites({this.offerIds = const {}, this.searches = const []});

  final Set<int> offerIds;
  final List<SavedSearch> searches;

  bool get isEmpty => offerIds.isEmpty && searches.isEmpty;

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

  /// Favoris déjà enregistrés sur cet appareil.
  var _savedLocally = false;
  Timer? _upload;

  @override
  Favorites build() {
    Future.microtask(() async {
      final saved = await ref
          .read(localStoreProvider)
          .readSetting<Object?>(_key);
      if (saved != null) {
        _savedLocally = true;
        state = Favorites.fromMap(saved);
      } else {
        _adoptAccount(ref.read(accountPreferencesProvider));
      }
    });
    // Nouvel appareil ou reconnexion : favoris du compte (serveur).
    ref.listen<Json>(accountPreferencesProvider, (_, next) {
      if (!_savedLocally) _adoptAccount(next);
    });
    ref.onDispose(() => _upload?.cancel());
    return const Favorites();
  }

  void _adoptAccount(Json account) {
    if (account['favorites'] case final Map<Object?, Object?> favorites) {
      state = Favorites.fromMap(favorites);
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
    _savedLocally = true;
    await ref.read(localStoreProvider).saveSetting(_key, favorites.toMap());
    if (ref.read(authTokenProvider) == null) return;
    // Plusieurs changements d'affilée : un seul envoi, après le dernier.
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
