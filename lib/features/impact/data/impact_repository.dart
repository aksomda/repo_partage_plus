import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';

/// Impact de l'utilisateur à la dernière synchronisation :
/// `pickups`, `food_kg`, `co2_kg`, `meals`.
final myImpactProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('impact')).value),
);

/// Répartition par catégorie de l'utilisateur connecté (camembert).
final myImpactByCategoryProvider = FutureProvider<List<Json>>((ref) async {
  final dio = ref.watch(dioProvider);
  final response = await dio.get(ApiEndpoints.myImpactByCategory);
  return List<Json>.from(
    (response.data as List).map((row) => Map<String, dynamic>.from(row as Map)),
  );
});

/// Évolution mensuelle de l'utilisateur connecté (graphique).
final myImpactMonthlyProvider = FutureProvider<List<Json>>((ref) async {
  final dio = ref.watch(dioProvider);
  final response = await dio.get(ApiEndpoints.myImpactMonthly);
  return List<Json>.from(
    (response.data as List).map((row) => Map<String, dynamic>.from(row as Map)),
  );
});