import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

/// Profil de l'utilisateur connecté (lu localement, disponible hors ligne).
final profileProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('profile')).value),
);

final isLoggedInProvider = Provider<bool>(
  (ref) => ref.watch(authTokenProvider) != null,
);

/// La première connexion exige le réseau ; ensuite la session est gardée
/// sur l'appareil et l'application s'ouvre même hors ligne.
class AuthRepository {
  AuthRepository(this._ref);

  final Ref _ref;

  Future<void> login(String email, String password) =>
      _authenticate(ApiEndpoints.login, {'email': email, 'password': password});

  /// [data] : champs attendus par POST /api/auth/register.
  Future<void> register(Map<String, Object?> data) =>
      _authenticate(ApiEndpoints.register, data);

  Future<void> _authenticate(String path, Map<String, Object?> body) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _ref.read(dioProvider).post(path, data: body);
    } on DioException catch (error) {
      if (error.response == null) {
        throw ApiException(
          'Connexion Internet requise pour se connecter la première fois',
        );
      }
      throw ApiException.fromDio(error);
    }

    final store = _ref.read(localStoreProvider);
    final token = response.data!['token'] as String;
    await store.saveToken(token);
    await store.saveSnapshot({'profile': response.data!['user']});
    _ref.read(authTokenProvider.notifier).set(token);

    // Copie locale complète en arrière-plan.
    _ref.read(syncControllerProvider.notifier).syncNow();
  }

  /// Actions encore en attente : les perdre si l'utilisateur se déconnecte.
  int get unsentActions => _ref.read(waitingActionsProvider).length;

  /// Efface la session et toutes les données locales.
  /// Vérifier [unsentActions] avant, et prévenir l'utilisateur.
  Future<void> logout() async {
    await _ref.read(localStoreProvider).clear();
    _ref.read(authTokenProvider.notifier).set(null);
  }
}

final authRepositoryProvider = Provider<AuthRepository>(AuthRepository.new);
