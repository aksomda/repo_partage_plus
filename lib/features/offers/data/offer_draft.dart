import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';

/// « Publication express » proposée aux restaurateurs connectés.
final canUseExpressDraftProvider = Provider<bool>(
  (ref) =>
      ref.watch(isLoggedInProvider) &&
      ref.watch(profileProvider)?['actor_code'] == 'restaurateur',
);

/// Brouillon d'offre rédigé par l'IA du serveur à partir d'une description
/// libre (texte ou dictée). Rien n'est publié : le formulaire est pré-rempli.
class OfferDraftRepository {
  OfferDraftRepository(this._ref);

  final Ref _ref;

  Future<Json> draft(String text, {DateTime? now}) async {
    final time = now ?? DateTime.now();
    try {
      final response = await _ref
          .read(dioProvider)
          .post<Map<String, dynamic>>(
            ApiEndpoints.offerDraft,
            data: {
              'text': text,
              'local_time':
                  '${time.hour.toString().padLeft(2, '0')}:'
                  '${time.minute.toString().padLeft(2, '0')}',
            },
          );
      final draft = response.data?['draft'];
      if (draft is! Map) throw ApiException('Réponse inattendue du serveur');
      return Map<String, dynamic>.from(draft);
    } on DioException catch (error) {
      if (error.response == null) throw ApiException.unreachable();
      throw ApiException.fromDio(error);
    }
  }
}

final offerDraftRepositoryProvider = Provider<OfferDraftRepository>(
  OfferDraftRepository.new,
);

/// Valeurs du formulaire tirées d'un brouillon : dates calculées à partir de
/// [now] (l'IA ne renvoie que des heures « HH:MM » et un nombre de jours).
typedef DraftDates = ({DateTime? expiry, DateTime? pickupStart, DateTime? pickupEnd});

DraftDates draftDates(Json draft, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final days = draft['expiry_in_days'];
  final expiry = days is int ? today.add(Duration(days: days)) : null;

  DateTime? at(Object? value) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch('${value ?? ''}');
    if (match == null) return null;
    return DateTime(
      today.year,
      today.month,
      today.day,
      int.parse(match[1]!),
      int.parse(match[2]!),
    );
  }

  // Heure de fin déjà passée aujourd'hui : créneau laissé au restaurateur.
  final end = at(draft['pickup_end']);
  if (end == null || !end.isAfter(now)) {
    return (expiry: expiry, pickupStart: null, pickupEnd: null);
  }
  var start = at(draft['pickup_start']) ?? now;
  if (start.isBefore(now)) start = now;
  if (!start.isBefore(end)) start = end.subtract(const Duration(hours: 1));
  return (
    expiry: expiry,
    pickupStart: DateTime(
      start.year,
      start.month,
      start.day,
      start.hour,
      start.minute,
    ),
    pickupEnd: end,
  );
}
