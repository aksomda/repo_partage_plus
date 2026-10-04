import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';

/// Impact de l'utilisateur à la dernière synchronisation :
/// `pickups`, `food_kg`, `co2_kg`, `meals`.
final myImpactProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('impact')).value),
);

/// Tableau de bord complet : compteurs, évolution mensuelle (12 mois,
/// mois vides inclus), répartition par catégorie, indicateurs sociaux.
/// Appel unique à `/impact/me/dashboard`.
final myImpactDashboardProvider = FutureProvider<Json>((ref) async {
  final dio = ref.watch(dioProvider);
  final response = await dio.get(ApiEndpoints.myImpactDashboard);
  return Map<String, dynamic>.from(response.data as Map);
});