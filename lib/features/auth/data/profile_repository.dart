import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
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

/// Modifications du profil : mises en file (hors ligne compris), sauf le
/// changement de mot de passe qui exige le réseau.
class ProfileRepository {
  ProfileRepository(this._sync, this._dio);

  final SyncController _sync;
  final Dio _dio;

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
      await _dio.put<void>(
        ApiEndpoints.changePassword,
        data: {'current_password': current, 'new_password': next},
      );
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
  ),
);
