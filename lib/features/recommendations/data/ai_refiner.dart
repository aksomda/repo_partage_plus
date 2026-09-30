import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/firebase/firebase_rest.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';

/// Classement renvoyé par l'IA : id des offres, dans l'ordre, avec une
/// justification courte.
class AiRefinement {
  const AiRefinement({required this.ranking, this.model});

  final List<({int id, String? reason})> ranking;
  final String? model;
}

/// L'IA n'a pas pu répondre (hors ligne, service indisponible, quota…).
/// Toujours rattrapée : l'application garde son classement local.
class AiUnavailable implements Exception {
  const AiUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Affinage des recommandations par un LLM. Remplaçable dans les tests.
abstract class AiRefiner {
  Future<AiRefinement> refine(Map<String, Object?> payload);
}

/// Appel de la Cloud Function `refineRecommendationsAi`, qui détient la clé
/// RodiumAI (jamais présente dans l'application).
class CloudFunctionAiRefiner implements AiRefiner {
  static const region = 'europe-west1';
  static const functionName = 'refineRecommendationsAi';
  static const timeout = Duration(seconds: 20);

  @override
  Future<AiRefinement> refine(Map<String, Object?> payload) async {
    if (Firebase.apps.isEmpty) {
      throw const AiUnavailable('IA non configurée dans cette version');
    }
    try {
      // La fonction exige une session Firebase : anonyme si besoin
      // (visiteurs sans compte, ou session applicative sans Firebase).
      final auth = FirebaseAuth.instance;
      if (auth.currentUser == null) await auth.signInAnonymously();

      final callable = FirebaseFunctions.instanceFor(region: region)
          .httpsCallable(
            functionName,
            options: HttpsCallableOptions(timeout: timeout),
          );
      final result = await callable.call<Map<String, dynamic>>(payload);
      return parseRefinement(result.data);
    } on FirebaseFunctionsException catch (error) {
      throw AiUnavailable(switch (error.code) {
        'resource-exhausted' => 'Limite d’appels à l’IA atteinte pour l’heure',
        'unauthenticated' => 'Session IA refusée',
        _ => 'Service d’IA indisponible',
      });
    } on FirebaseAuthException {
      throw const AiUnavailable('Connexion au service d’IA impossible');
    } on AiUnavailable {
      rethrow;
    } catch (error) {
      debugPrint('Affinage IA : $error');
      throw const AiUnavailable('Service d’IA indisponible');
    }
  }
}

/// Lit la réponse de la fonction ; ignore toute entrée mal formée.
AiRefinement parseRefinement(Object? data) {
  if (data is! Map) throw const AiUnavailable('Réponse de l’IA invalide');
  final ranking = <({int id, String? reason})>[];
  for (final item in data['ranking'] as List? ?? const []) {
    if (item is Map && item['id'] is int) {
      ranking.add((id: item['id'] as int, reason: item['reason'] as String?));
    }
  }
  if (ranking.isEmpty) throw const AiUnavailable('Réponse de l’IA vide');
  return AiRefinement(ranking: ranking, model: data['model'] as String?);
}

/// Même Cloud Function, appelée en HTTPS (protocole « callable » documenté
/// par Firebase) : Windows / Linux / macOS, sans le paquet cloud_functions.
class CallableRestAiRefiner implements AiRefiner {
  CallableRestAiRefiner({
    required this.dio,
    required this.config,
    required this.session,
  });

  final Dio dio;
  final FirebaseRestConfig? config;
  final AnonymousRestSession? session;

  @override
  Future<AiRefinement> refine(Map<String, Object?> payload) async {
    final config = this.config;
    final session = this.session;
    if (config == null || session == null) {
      throw const AiUnavailable('IA non configurée dans cette version');
    }
    try {
      final token = await session.idToken();
      final response = await dio.post<Map<String, dynamic>>(
        'https://${CloudFunctionAiRefiner.region}-${config.projectId}'
        '.cloudfunctions.net/${CloudFunctionAiRefiner.functionName}',
        data: {'data': payload},
        options: Options(
          headers: {'Authorization': 'Bearer $token'},
          receiveTimeout: CloudFunctionAiRefiner.timeout,
        ),
      );
      return parseRefinement(response.data?['result']);
    } on DioException catch (error) {
      final data = error.response?.data;
      final status = data is Map && data['error'] is Map
          ? (data['error'] as Map)['status']
          : null;
      throw AiUnavailable(switch (status) {
        'RESOURCE_EXHAUSTED' => 'Limite d’appels à l’IA atteinte pour l’heure',
        _ => 'Service d’IA indisponible',
      });
    } on AiUnavailable {
      rethrow;
    } catch (error) {
      debugPrint('Affinage IA (HTTPS) : $error');
      throw const AiUnavailable('Service d’IA indisponible');
    }
  }
}

/// IA intégrée à notre serveur (POST /recommendations/refine) : les offres
/// et l'historique sont relus dans MySQL, seuls les id sont envoyés.
/// Fonctionne sans Firebase, sur toutes les plateformes.
class ServerAiRefiner implements AiRefiner {
  ServerAiRefiner(this.dio);

  final Dio dio;

  @override
  Future<AiRefinement> refine(Map<String, Object?> payload) async {
    final origin = payload['origin'];
    final history = payload['history'];
    try {
      final response = await dio.post<Map<String, dynamic>>(
        ApiEndpoints.refineRecommendations,
        data: {
          'candidates': [
            for (final item in payload['candidates'] as List? ?? const [])
              if (item is Map)
                {'id': item['id'], 'local_score': item['local_score']},
          ],
          'preferences_text': payload['preferences_text'],
          'preferred_categories': payload['preferred_categories'],
          'preferred_publishers': payload['preferred_publishers'],
          'max_price': payload['max_price'],
          'max_distance_km': payload['max_distance_km'],
          if (origin is Map) 'latitude': origin['lat'],
          if (origin is Map) 'longitude': origin['lng'],
          if (history is Map) 'recent_titles': history['recent_titles'],
        },
      );
      return parseRefinement(response.data);
    } on DioException catch (error) {
      if (error.response == null) {
        throw const AiUnavailable('Serveur injoignable');
      }
      throw AiUnavailable(switch (error.response!.statusCode) {
        429 => 'Limite d’appels à l’IA atteinte pour l’heure',
        _ => ApiException.fromDio(error).message,
      });
    } on AiUnavailable {
      rethrow;
    } catch (error) {
      debugPrint('Affinage IA (serveur) : $error');
      throw const AiUnavailable('Service d’IA indisponible');
    }
  }
}

/// Essaie chaque IA dans l'ordre ; la première qui répond l'emporte.
/// Si toutes échouent, l'erreur de la dernière est renvoyée (et
/// l'application garde son classement local).
class FallbackAiRefiner implements AiRefiner {
  const FallbackAiRefiner(this.refiners);

  final List<AiRefiner> refiners;

  @override
  Future<AiRefinement> refine(Map<String, Object?> payload) async {
    AiUnavailable? last;
    for (final refiner in refiners) {
      try {
        return await refiner.refine(payload);
      } on AiUnavailable catch (error) {
        last = error;
      } catch (error) {
        last = AiUnavailable('$error');
      }
    }
    throw last ?? const AiUnavailable('Service d’IA indisponible');
  }
}

/// Cloud Function (SDK sur mobile et web, HTTPS sur ordinateur), puis IA du
/// serveur en repli (Firebase non configuré, indisponible, ou quota atteint).
final aiRefinerProvider = Provider<AiRefiner>(
  (ref) => FallbackAiRefiner([
    if (isDesktop)
      CallableRestAiRefiner(
        dio: ref.watch(googleDioProvider),
        config: ref.watch(firebaseRestConfigProvider),
        session: ref.watch(anonymousRestSessionProvider),
      )
    else
      CloudFunctionAiRefiner(),
    ServerAiRefiner(ref.watch(dioProvider)),
  ]),
);
