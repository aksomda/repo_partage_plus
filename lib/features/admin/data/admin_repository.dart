import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';

Json? _adminSnapshot(Ref ref) =>
    asJson(ref.watch(snapshotProvider('admin')).value);

/// Offres à modérer, sans celles déjà traitées hors ligne.
final pendingOffersProvider = Provider<List<Json>>((ref) {
  final handled = {
    for (final action in ref.watch(waitingActionsProvider))
      if (action.kind == 'offer.moderate') action.targetId,
  };
  return asJsonList(
    _adminSnapshot(ref)?['pending_offers'],
  ).where((offer) => !handled.contains(offer['id'])).toList();
});

/// Associations à valider, sans celles déjà traitées hors ligne.
final pendingAssociationsProvider = Provider<List<Json>>((ref) {
  final handled = {
    for (final action in ref.watch(waitingActionsProvider))
      if (action.kind == 'association.review') action.targetId,
  };
  return asJsonList(
    _adminSnapshot(ref)?['pending_associations'],
  ).where((association) => !handled.contains(association['id'])).toList();
});

final factorsProvider = Provider<List<Json>>(
  (ref) => asJsonList(_adminSnapshot(ref)?['factors']),
);

/// Toutes les décisions d'administration passent par la file :
/// un admin peut modérer hors ligne, l'envoi se fait au retour du réseau.
class AdminRepository {
  AdminRepository(this._sync);

  final SyncController _sync;

  Future<SubmitResult> moderateOffer(
    Json offer, {
    required bool approve,
    String? reason,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'offer.moderate',
        method: 'PATCH',
        path: ApiEndpoints.moderateOffer(offer['id'] as int),
        body: {'decision': approve ? 'approve' : 'reject', 'reason': ?reason},
        targetId: offer['id'] as int,
        label: '${approve ? 'Validation' : 'Refus'} de « ${offer['title']} »',
      ),
    );
  }

  Future<SubmitResult> reviewAssociation(
    Json association, {
    required bool approve,
    String? reason,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'association.review',
        method: 'PATCH',
        path: ApiEndpoints.reviewAssociation(association['id'] as int),
        body: {'decision': approve ? 'approve' : 'reject', 'reason': ?reason},
        targetId: association['id'] as int,
        label:
            '${approve ? 'Validation' : 'Refus'} de « ${association['name']} »',
      ),
    );
  }

  Future<SubmitResult> setUserStatus(
    int userId, {
    required bool suspended,
    String? reason,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'user.status',
        method: 'PATCH',
        path: ApiEndpoints.userStatus(userId),
        body: {'status': suspended ? 'suspended' : 'active', 'reason': ?reason},
        targetId: userId,
        label: suspended ? 'Suspension du compte' : 'Réactivation du compte',
      ),
    );
  }

  Future<SubmitResult> saveCategory({
    int? id,
    required String name,
    String? icon,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'category.save',
        method: id == null ? 'POST' : 'PUT',
        path: id == null
            ? ApiEndpoints.adminCategories
            : ApiEndpoints.adminCategory(id),
        body: {'name': name, 'icon': icon},
        targetId: id,
        label: 'Catégorie « $name »',
      ),
    );
  }

  Future<SubmitResult> deleteCategory(int id, String name) {
    return _sync.submit(
      PendingAction(
        kind: 'category.delete',
        method: 'DELETE',
        path: ApiEndpoints.adminCategory(id),
        targetId: id,
        label: 'Suppression de « $name »',
      ),
    );
  }

  Future<SubmitResult> saveFactor({
    int? id,
    required int categoryId,
    required double co2KgPerKg,
    double mealsPerKg = 2.5,
    String? source,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'factor.save',
        method: id == null ? 'POST' : 'PUT',
        path: id == null
            ? ApiEndpoints.adminFactors
            : ApiEndpoints.adminFactor(id),
        body: {
          'category_id': categoryId,
          'co2_kg_per_kg': co2KgPerKg,
          'meals_per_kg': mealsPerKg,
          'source': source,
        },
        targetId: id,
        label: 'Facteur d’impact',
      ),
    );
  }

  Future<SubmitResult> deleteFactor(int id) {
    return _sync.submit(
      PendingAction(
        kind: 'factor.delete',
        method: 'DELETE',
        path: ApiEndpoints.adminFactor(id),
        targetId: id,
        label: 'Suppression d’un facteur',
      ),
    );
  }
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.read(syncControllerProvider.notifier)),
);
