import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_config.dart';

/// Jeton lu dans la base locale au démarrage (surchargé dans main()),
/// pour rester connecté sans réseau.
final initialTokenProvider = Provider<String?>((ref) => null);

/// Jeton JWT de la session en cours (null si déconnecté).
class AuthToken extends Notifier<String?> {
  @override
  String? build() => ref.read(initialTokenProvider);

  void set(String? token) => state = token;
}

final authTokenProvider = NotifierProvider<AuthToken, String?>(AuthToken.new);

/// Erreur renvoyée par l'API, avec le message lisible du champ `error`.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.code, this.details});

  final String message;
  final int? statusCode;

  /// Code métier renvoyé dans `details.code` (ex. `account_pending`).
  final String? code;
  final Map<String, dynamic>? details;

  /// true si le serveur n'a pas pu être joint.
  bool get isNetwork => statusCode == null;

  /// Aucune réponse du serveur : pas de réseau, ou API injoignable (serveur
  /// arrêté, mauvaise adresse). En développement, l'adresse visée est
  /// affichée pour repérer une mauvaise valeur de API_BASE_URL.
  factory ApiException.unreachable() => ApiException(
    'Serveur injoignable : vérifiez votre connexion Internet '
    'ou réessayez dans un instant'
    '${kDebugMode ? '\n(API : ${ApiConfig.baseUrl})' : ''}',
  );

  factory ApiException.fromDio(DioException error) {
    final data = error.response?.data;
    final message = data is Map && data['error'] is String
        ? data['error'] as String
        : 'Impossible de joindre le serveur';
    final details = data is Map && data['details'] is Map
        ? Map<String, dynamic>.from(data['details'] as Map)
        : null;
    return ApiException(
      message,
      statusCode: error.response?.statusCode,
      code: details?['code'] as String?,
      details: details,
    );
  }

  @override
  String toString() => message;
}

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      // Render (offre gratuite) met ~50 s à réveiller l'API après 15 min d'inactivité.
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = ref.read(authTokenProvider);
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
        handler.next(options);
      },
    ),
  );

  ref.onDispose(dio.close);
  return dio;
});
