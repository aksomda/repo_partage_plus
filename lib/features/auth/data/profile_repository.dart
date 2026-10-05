import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';

/// Actions de profil envoyées immédiatement si le réseau est disponible,
/// sinon conservées dans la file offline.
class ProfileRepository {
  ProfileRepository(this._sync);

  final SyncController _sync;

  /// Le backend /api/users/me accepte actuellement:
  /// - name
  /// - phone
  /// - latitude
  /// - longitude
  ///
  /// first_name, last_name, gender et age sont actuellement renvoyés par
  /// l'API mais ne sont pas modifiables par PATCH /users/me.
  Future<SubmitResult> updateProfile({
    required String name,
    required String phone,
    double? latitude,
    double? longitude,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'profile.update',
        method: 'PATCH',
        path: ApiEndpoints.updateMe,
        body: {
          'name': name,
          'phone': phone,
          'latitude': latitude,
          'longitude': longitude,
        },
        label: 'Mise à jour du profil',
      ),
    );
  }

  Future<SubmitResult> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'profile.password',
        method: 'PUT',
        path: ApiEndpoints.changePassword,
        body: {
          'current_password': currentPassword,
          'new_password': newPassword,
        },
        label: 'Changement du mot de passe',
      ),
    );
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.read(syncControllerProvider.notifier)),
);
