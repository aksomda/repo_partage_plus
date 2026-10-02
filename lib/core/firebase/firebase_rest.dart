import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/firebase_options.dart';

/// Windows, Linux, macOS : les paquets Firebase n'y sont pas utilisables en
/// production. On passe alors par les API HTTP officielles de Firebase.
bool get isDesktop =>
    !kIsWeb &&
    const {
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);

/// Clé et projet Firebase utilisés par les appels HTTP (configuration web,
/// valable sur toutes les plateformes). null : Firebase non configuré.
class FirebaseRestConfig {
  const FirebaseRestConfig({required this.apiKey, required this.projectId});

  final String apiKey;
  final String projectId;
}

final firebaseRestConfigProvider = Provider<FirebaseRestConfig?>((ref) {
  try {
    final web = DefaultFirebaseOptions.web;
    return FirebaseRestConfig(apiKey: web.apiKey, projectId: web.projectId);
  } catch (_) {
    return null;
  }
});

/// Client HTTP pour les API Google (Identity Toolkit, Secure Token,
/// Cloud Functions), distinct de celui de notre API.
final googleDioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      contentType: Headers.jsonContentType,
    ),
  );
  ref.onDispose(dio.close);
  return dio;
});

/// Message d'erreur renvoyé par une API Google (`EMAIL_EXISTS`…), ou null.
String? googleErrorCode(DioException error) {
  final data = error.response?.data;
  if (data is Map && data['error'] is Map) {
    final message = (data['error'] as Map)['message'];
    // « WEAK_PASSWORD : Password should be… » → WEAK_PASSWORD
    if (message is String) return message.split(' ').first.trim();
  }
  return null;
}

/// Session Firebase anonyme obtenue par HTTP, gardée sur l'appareil : sert à
/// appeler les Cloud Functions depuis Windows / Linux / macOS.
class AnonymousRestSession {
  AnonymousRestSession({
    required this.dio,
    required this.config,
    required this.store,
  });

  final Dio dio;
  final FirebaseRestConfig config;
  final LocalStore store;

  static const _refreshKey = 'firebase_anonymous_refresh';

  String? _idToken;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Jeton d'identité valide (renouvelé automatiquement).
  Future<String> idToken() async {
    if (_idToken != null &&
        DateTime.now().isBefore(
          _expiresAt.subtract(const Duration(minutes: 5)),
        )) {
      return _idToken!;
    }

    final refresh = await store.readSetting<String>(_refreshKey);
    if (refresh != null) {
      try {
        final response = await dio.post<Map<String, dynamic>>(
          'https://securetoken.googleapis.com/v1/token',
          queryParameters: {'key': config.apiKey},
          data: {'grant_type': 'refresh_token', 'refresh_token': refresh},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
        return _keep(
          response.data!['id_token'] as String,
          response.data!['refresh_token'] as String,
          response.data!['expires_in'],
        );
      } on DioException catch (error) {
        // Session révoquée : on en crée une nouvelle ; réseau : on abandonne.
        if (error.response == null) rethrow;
      }
    }

    final response = await dio.post<Map<String, dynamic>>(
      'https://identitytoolkit.googleapis.com/v1/accounts:signUp',
      queryParameters: {'key': config.apiKey},
      data: {'returnSecureToken': true},
    );
    return _keep(
      response.data!['idToken'] as String,
      response.data!['refreshToken'] as String,
      response.data!['expiresIn'],
    );
  }

  Future<String> _keep(
    String idToken,
    String refresh,
    Object? expiresIn,
  ) async {
    _idToken = idToken;
    _expiresAt = DateTime.now().add(
      Duration(seconds: int.tryParse('$expiresIn') ?? 3600),
    );
    await store.saveSetting(_refreshKey, refresh);
    return idToken;
  }
}

final anonymousRestSessionProvider = Provider<AnonymousRestSession?>((ref) {
  final config = ref.watch(firebaseRestConfigProvider);
  if (config == null) return null;
  return AnonymousRestSession(
    dio: ref.watch(googleDioProvider),
    config: config,
    store: ref.watch(localStoreProvider),
  );
});
