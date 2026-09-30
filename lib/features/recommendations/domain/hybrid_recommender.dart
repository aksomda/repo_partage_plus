import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/recommendations/data/ai_refiner.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';
import 'package:repo_partage_plus/features/recommendations/domain/local_ranker.dart';

/// Niveau 1 : classement local, recalculé à chaque changement de données,
/// de position ou de préférences. Toujours disponible, même hors ligne.
final localRecommendationsProvider = Provider<List<RankedOffer>>((ref) {
  return const LocalRanker().rank(
    ref.watch(availableOffersProvider),
    origin: ref.watch(originProvider).place,
    preferences: ref.watch(recoPreferencesProvider),
    history: ref.watch(userHistoryProvider),
    now: DateTime.now(),
    excludeDonorId: ref.watch(profileProvider)?['id'] as int?,
  );
});

/// Données envoyées à l'IA : les [aiCandidateLimit] premières offres du
/// classement local, les préférences et un résumé de l'historique.
Map<String, Object?> buildAiPayload({
  required List<RankedOffer> ranked,
  required RecoPreferences preferences,
  required UserHistory history,
  required List<Json> categories,
  Place? origin,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final names = {for (final c in categories) c['id']: c['name']};
  final topCategories = history.categoryCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return {
    'preferences_text': preferences.text,
    'preferred_categories': [
      for (final id in preferences.categoryIds)
        if (names[id] != null) names[id],
    ],
    'preferred_publishers': [
      for (final type in preferences.publisherTypes)
        publisherLabels[type] ?? type,
    ],
    'max_price': preferences.maxPrice,
    'max_distance_km': preferences.maxDistanceKm,
    'history': {
      'recent_titles': history.recentTitles,
      'reserved_titles': history.reservedTitles,
      'top_categories': [
        for (final entry in topCategories.take(5))
          if (names[entry.key] != null) names[entry.key],
      ],
    },
    // Pour l'IA du serveur, qui recalcule les distances depuis MySQL.
    'origin': origin == null ? null : {'lat': origin.lat, 'lng': origin.lng},
    'candidates': [
      for (final item in ranked.take(aiCandidateLimit))
        {
          'id': item.id,
          'title': item.offer['title'],
          'category': item.offer['category_name'],
          'publisher_type': item.offer['publisher_type'],
          'distance_km': item.distanceKm,
          'days_to_expiry': DateTime.parse(
            item.offer['expiry_date'] as String,
          ).difference(DateTime(today.year, today.month, today.day)).inDays,
          'price': item.offer['price'] ?? 0,
          'local_score': item.score.total,
        },
    ],
  };
}

/// Ordre final : les offres choisies par l'IA (encore disponibles), puis le
/// reste dans l'ordre local. Aucune offre n'est perdue ni inventée.
List<RankedOffer> mergeRanking(
  List<RankedOffer> local,
  AiRefinement refinement,
) {
  final byId = {for (final item in local) item.id: item};
  final used = <int>{};
  final merged = <RankedOffer>[];
  for (final entry in refinement.ranking) {
    final item = byId[entry.id];
    if (item != null && used.add(entry.id)) {
      merged.add(item.withAiReason(entry.reason));
    }
  }
  return [
    ...merged,
    for (final item in local)
      if (!used.contains(item.id)) item,
  ];
}

/// Origine du classement affiché.
enum RecoSource { local, ai }

class RecoStatus {
  const RecoStatus({
    this.refinement,
    this.refining = false,
    this.notice,
    this.refinedAt,
    this.wanted = false,
  });

  final AiRefinement? refinement;
  final bool refining;

  /// Message affiché quand on reste sur le classement local.
  final String? notice;
  final DateTime? refinedAt;

  /// L'utilisateur est sur l'écran : affiner dès que le réseau revient.
  final bool wanted;

  RecoStatus copyWith({
    AiRefinement? Function()? refinement,
    bool? refining,
    String? Function()? notice,
    DateTime? refinedAt,
    bool? wanted,
  }) {
    return RecoStatus(
      refinement: refinement == null ? this.refinement : refinement(),
      refining: refining ?? this.refining,
      notice: notice == null ? this.notice : notice(),
      refinedAt: refinedAt ?? this.refinedAt,
      wanted: wanted ?? this.wanted,
    );
  }
}

/// Niveau 2 : affinage par l'IA quand le réseau est là. En cas d'absence de
/// réseau ou d'erreur, on garde le classement local, sans interruption.
class RecommendationsController extends Notifier<RecoStatus> {
  /// Cloud Function puis, en repli, IA du serveur : délai total.
  static const maxWait = Duration(seconds: 45);

  @override
  RecoStatus build() {
    // Retour du réseau : on relance l'affinage si l'utilisateur l'attend.
    ref.listen(syncControllerProvider.select((sync) => sync.online), (
      previous,
      online,
    ) {
      if (online && previous == false && state.wanted) refine();
    });
    // Nouvelles préférences : l'ancien affinage ne correspond plus.
    ref.listen(recoPreferencesProvider, (_, _) {
      state = state.copyWith(refinement: () => null, notice: () => null);
    });
    return const RecoStatus();
  }

  /// Demande un affinage ; sans effet visible en cas d'échec (repli local).
  Future<void> refine() async {
    state = state.copyWith(wanted: true);
    if (!ref.read(syncControllerProvider).online) {
      state = state.copyWith(
        notice: () => 'Hors ligne : classement calculé sur l’appareil',
      );
      return;
    }
    final ranked = ref.read(localRecommendationsProvider);
    if (ranked.isEmpty || state.refining) return;

    state = state.copyWith(refining: true, notice: () => null);
    try {
      final payload = buildAiPayload(
        ranked: ranked,
        preferences: ref.read(recoPreferencesProvider),
        history: ref.read(userHistoryProvider),
        categories: ref.read(categoriesProvider),
        origin: ref.read(originProvider).place,
      );
      final refinement = await ref
          .read(aiRefinerProvider)
          .refine(payload)
          .timeout(maxWait);
      state = state.copyWith(
        refinement: () => refinement,
        refining: false,
        refinedAt: DateTime.now(),
      );
    } catch (error) {
      // Aucune erreur ne remonte : repli sur le score local.
      state = state.copyWith(
        refining: false,
        notice: () => error is AiUnavailable
            ? '${error.message} : classement local'
            : 'IA indisponible : classement local',
      );
    }
  }
}

final recommendationsControllerProvider =
    NotifierProvider<RecommendationsController, RecoStatus>(
      RecommendationsController.new,
    );

/// Liste affichée : ordre de l'IA si disponible et en ligne, sinon local.
final recommendationsProvider =
    Provider<({List<RankedOffer> items, RecoSource source})>((ref) {
      final local = ref.watch(localRecommendationsProvider);
      final status = ref.watch(recommendationsControllerProvider);
      final online = ref.watch(syncControllerProvider.select((s) => s.online));
      final refinement = status.refinement;
      if (!online || refinement == null) {
        return (items: local, source: RecoSource.local);
      }
      return (items: mergeRanking(local, refinement), source: RecoSource.ai);
    });
