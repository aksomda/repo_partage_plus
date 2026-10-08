import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';

/// Préférences du compte (`users.preferences`), modifications pas encore
/// envoyées comprises : `reco`, `push_enabled`, `favorites`…
final accountPreferencesProvider = Provider<Json>((ref) {
  final saved = asJson(ref.watch(profileProvider)?['preferences']) ?? {};
  return {
    ...saved,
    for (final action in ref.watch(waitingActionsProvider))
      if (action.kind == 'profile.update' && !action.isRejected)
        ...?asJson(action.body?['preferences']),
  };
});

/// Notifications push acceptées (oui par défaut).
final pushEnabledProvider = Provider<bool>(
  (ref) => ref.watch(accountPreferencesProvider)['push_enabled'] != false,
);

/// Alerte quand une nouvelle offre correspond à une recherche enregistrée
/// (oui par défaut ; toujours active sans compte).
final searchAlertsEnabledProvider = Provider<bool>(
  (ref) => ref.watch(accountPreferencesProvider)['search_alerts'] != false,
);

/// Modifications du profil : mises en file (hors ligne compris), sauf le
/// changement de mot de passe et la photo de profil, qui exigent le réseau.
class ProfileRepository {
  ProfileRepository(this._sync, this._dio, this._store, this._setToken);

  final SyncController _sync;
  final Dio _dio;
  final LocalStore _store;

  /// Remplace le jeton de la session en cours.
  final void Function(String token) _setToken;

  /// Ajoute ou remplace la photo de profil (`data:image/jpeg;base64,…`) ;
  /// null la retire. La copie locale du profil suit tout de suite.
  Future<void> setPhoto(String? dataUrl) async {
    try {
      final response = dataUrl == null
          ? await _dio.delete<Map<String, dynamic>>(ApiEndpoints.myPhoto)
          : await _dio.put<Map<String, dynamic>>(
              ApiEndpoints.myPhoto,
              data: {'photo': dataUrl},
            );
      await _store.patchSnapshot('profile', {
        'photo_path': response.data?['photo_path'],
        'photo_updated_at': response.data?['photo_updated_at'],
      });
    } on DioException catch (error) {
      if (error.response == null) throw ApiException.unreachable();
      throw ApiException.fromDio(error);
    }
  }

  Future<SubmitResult> update({
    String? firstName,
    String? lastName,
    String? phone,
    double? latitude,
    double? longitude,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'profile.update',
        method: 'PATCH',
        path: ApiEndpoints.updateMe,
        body: {
          'first_name': ?firstName,
          'last_name': ?lastName,
          'phone': ?phone,
          'latitude': ?latitude,
          'longitude': ?longitude,
        },
        label: 'Mise à jour du profil',
      ),
    );
  }

  /// Fusionnées avec les préférences enregistrées (une clé à null est
  /// supprimée) : retrouvées sur les autres appareils du compte.
  Future<SubmitResult> savePreferences(Json preferences) {
    return _sync.submit(
      PendingAction(
        kind: 'profile.update',
        method: 'PATCH',
        path: ApiEndpoints.updateMe,
        body: {'preferences': preferences},
        label: 'Préférences',
      ),
    );
  }

  Future<void> changePassword({
    required String current,
    required String next,
  }) async {
    try {
      final response = await _dio.put<Map<String, dynamic>>(
        ApiEndpoints.changePassword,
        data: {'current_password': current, 'new_password': next},
      );
      // Les autres sessions du compte sont révoquées par le serveur ; celle-ci
      // continue avec le nouveau jeton.
      final token = response.data?['token'];
      if (token is String) {
        await _store.saveToken(token);
        _setToken(token);
      }
    } on DioException catch (error) {
      if (error.response == null) throw ApiException.unreachable();
      throw ApiException.fromDio(error);
    }
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(
    ref.read(syncControllerProvider.notifier),
    ref.read(dioProvider),
    ref.read(localStoreProvider),
    (token) => ref.read(authTokenProvider.notifier).set(token),
  ),
);
