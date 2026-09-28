import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';

/// Impact de l'utilisateur à la dernière synchronisation :
/// `pickups`, `food_kg`, `co2_kg`, `meals`.
final myImpactProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('impact')).value),
);
