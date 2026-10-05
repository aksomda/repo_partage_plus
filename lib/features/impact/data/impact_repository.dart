import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

// Toutes les données d'impact viennent de l'instantané gardé sur l'appareil
// (synchronisation) : l'écran s'affiche hors ligne et se met à jour après
// chaque synchronisation, par exemple juste après un retrait.

/// Compteurs : `pickups`, `items`, `food_kg`, `co2_kg`, `meals`.
final myImpactProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('impact')).value),
);

/// Compteurs de toute la plateforme (`food_kg`, `meals`, `co2_kg`,
/// `users`…), avec ou sans compte : affichés sur l'accueil, hors ligne aussi.
final publicImpactProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('public_impact')).value),
);

/// Les 12 derniers mois (`month` « 2026-09 », mêmes mesures), mois vides compris.
final myImpactMonthlyProvider = Provider<List<Json>>(
  (ref) => asJsonList(ref.watch(snapshotProvider('impact_monthly')).value),
);

/// Répartition par catégorie (`category_name`, `food_kg`…), la plus forte d'abord.
final myImpactByCategoryProvider = Provider<List<Json>>(
  (ref) => asJsonList(ref.watch(snapshotProvider('impact_by_category')).value),
);

/// Indicateurs sociaux : personnes aidées, donateurs rencontrés…
final myImpactSocialProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('impact_social')).value),
);

/// Date de calcul des chiffres affichés, et leur source (`mysql` ou
/// `firestore` pour la copie de secours).
final myImpactAsOfProvider = Provider<(DateTime?, String?)>((ref) {
  final asOf = ref.watch(snapshotProvider('impact_as_of')).value;
  final source = ref.watch(snapshotProvider('impact_source')).value;
  return (
    asOf is String ? DateTime.tryParse(asOf)?.toLocal() : null,
    source is String ? source : null,
  );
});

/// Résultat d'une actualisation de l'écran « Mon impact ».
enum ImpactRefresh {
  /// Chiffres à jour.
  done,

  /// Serveur indisponible (MySQL) : copie de secours Firebase affichée.
  backup,

  /// Hors ligne ou serveur injoignable : dernière copie de l'appareil gardée.
  offline,
}

class ImpactRepository {
  ImpactRepository(this._ref);

  final Ref _ref;

  /// Synchronise tout, puis relit le tableau de bord : si MySQL est en
  /// panne, le serveur renvoie la dernière copie gardée dans Firebase.
  Future<ImpactRefresh> refresh() async {
    if (!_ref.read(syncControllerProvider).online) return ImpactRefresh.offline;
    await _ref.read(syncControllerProvider.notifier).syncNow();
    try {
      final response = await _ref
          .read(dioProvider)
          .get<Map<String, dynamic>>(ApiEndpoints.myImpactDashboard);
      final data = response.data ?? const {};
      final source = data['source'] as String? ?? 'mysql';
      await _ref.read(localStoreProvider).saveSnapshot({
        'impact': data['impact'],
        'impact_monthly': data['impact_monthly'],
        'impact_by_category': data['impact_by_category'],
        'impact_social': data['impact_social'],
        'impact_as_of': data['as_of'],
        'impact_source': source,
      });
      return source == 'firestore' ? ImpactRefresh.backup : ImpactRefresh.done;
    } on DioException {
      return ImpactRefresh.offline;
    }
  }
}

final impactRepositoryProvider = Provider<ImpactRepository>(
  ImpactRepository.new,
);
