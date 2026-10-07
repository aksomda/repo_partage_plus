import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/features/recommendations/data/offer_search_agent.dart';
import 'package:repo_partage_plus/features/recommendations/data/voice_recorder.dart';
import 'package:repo_partage_plus/features/recommendations/domain/local_ranker.dart';

/// Étape de la recherche par la voix ou le texte.
enum OfferSearchPhase { idle, recording, thinking }

class OfferSearchState {
  const OfferSearchState({
    this.phase = OfferSearchPhase.idle,
    this.result,
    this.startedAt,
  });

  final OfferSearchPhase phase;

  /// Filtre appliqué à la liste ; null : toutes les recommandations.
  final OfferSearchResult? result;

  /// Début de l'enregistrement (durée affichée).
  final DateTime? startedAt;

  OfferSearchState copyWith({
    OfferSearchPhase? phase,
    OfferSearchResult? Function()? result,
    DateTime? startedAt,
  }) => OfferSearchState(
    phase: phase ?? this.phase,
    result: result == null ? this.result : result(),
    startedAt: startedAt ?? this.startedAt,
  );
}

/// Issue d'une recherche, pour l'écran (message à afficher).
sealed class OfferSearchOutcome {
  const OfferSearchOutcome();
}

class SearchDone extends OfferSearchOutcome {
  const SearchDone(this.result);

  final OfferSearchResult result;
}

/// L'IA ne comprend pas l'audio ici ou a échoué : dictée de l'appareil.
class SearchNeedsDictation extends OfferSearchOutcome {
  const SearchNeedsDictation(this.reason);

  final String? reason;
}

class SearchFailed extends OfferSearchOutcome {
  const SearchFailed(this.message);

  final String message;
}

/// Offres envoyées à l'agent : les mieux classées, informations publiques.
List<Map<String, Object?>> searchCandidates(List<RankedOffer> items) => [
  for (final item in items.take(80))
    candidateSummary(item.offer, distanceKm: item.distanceKm),
];

/// Enregistre la demande, la fait retranscrire et filtrer par l'agent IA.
class OfferSearchController extends Notifier<OfferSearchState> {
  /// Au-delà, l'enregistrement s'arrête et part seul.
  static const maxRecording = Duration(seconds: 30);

  Timer? _limit;

  @override
  OfferSearchState build() {
    ref.onDispose(() => _limit?.cancel());
    return const OfferSearchState();
  }

  OfferSearchAgent get _agent => ref.read(offerSearchAgentProvider);

  /// Démarre l'enregistrement ; [onLimit] : arrêt automatique (30 s).
  /// Renvoie [SearchNeedsDictation] si l'audio n'est pas pris en charge.
  Future<OfferSearchOutcome?> startRecording({
    required void Function() onLimit,
  }) async {
    if (!_agent.understandsAudio) return const SearchNeedsDictation(null);
    final started = await ref.read(voiceRecorderProvider).start();
    if (!started) {
      return const SearchNeedsDictation('Micro indisponible ou refusé');
    }
    state = state.copyWith(
      phase: OfferSearchPhase.recording,
      startedAt: DateTime.now(),
    );
    _limit?.cancel();
    _limit = Timer(maxRecording, onLimit);
    return null;
  }

  /// Arrête l'enregistrement et envoie l'audio à l'agent.
  Future<OfferSearchOutcome> stopAndSearch(List<RankedOffer> items) async {
    _limit?.cancel();
    final audio = await ref.read(voiceRecorderProvider).stop();
    if (audio == null) {
      state = state.copyWith(phase: OfferSearchPhase.idle);
      return const SearchFailed('Rien n’a été enregistré');
    }
    state = state.copyWith(phase: OfferSearchPhase.thinking);
    try {
      final result = await _agent.search(
        audio: audio,
        candidates: searchCandidates(items),
      );
      state = OfferSearchState(result: result);
      return SearchDone(result);
    } on OfferSearchUnavailable catch (error) {
      state = state.copyWith(phase: OfferSearchPhase.idle);
      return SearchNeedsDictation(error.message);
    }
  }

  Future<void> cancelRecording() async {
    _limit?.cancel();
    await ref.read(voiceRecorderProvider).cancel();
    state = state.copyWith(phase: OfferSearchPhase.idle);
  }

  /// Demande écrite (ou dictée) : filtre ; texte vide : plus de filtre.
  Future<OfferSearchOutcome?> searchText(
    String text,
    List<RankedOffer> items,
  ) async {
    if (text.trim().isEmpty) {
      clear();
      return null;
    }
    state = state.copyWith(phase: OfferSearchPhase.thinking);
    try {
      final result = await _agent.search(
        text: text.trim(),
        candidates: searchCandidates(items),
      );
      state = OfferSearchState(result: result);
      return SearchDone(result);
    } on OfferSearchUnavailable catch (error) {
      state = state.copyWith(phase: OfferSearchPhase.idle);
      return SearchFailed(error.message);
    }
  }

  void clear() => state = const OfferSearchState();
}

final offerSearchProvider =
    NotifierProvider<OfferSearchController, OfferSearchState>(
      OfferSearchController.new,
    );

/// Recommandations restreintes aux offres retenues par l'agent, dans son
/// ordre ; toutes si aucun filtre.
List<RankedOffer> applySearch(
  List<RankedOffer> items,
  OfferSearchResult? result,
) {
  if (result == null) return items;
  final byId = {for (final item in items) item.id: item};
  return [for (final id in result.keepIds) ?byId[id]];
}
