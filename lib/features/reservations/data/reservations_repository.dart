import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';

// ---------- Lecture ----------

/// Réservations du bénéficiaire. Celles faites hors ligne apparaissent avec
/// `status: 'pending_sync'` et `local: true` (pas encore de code de retrait).
/// Le code de retrait des réservations synchronisées reste lisible hors ligne.
final myReservationsProvider = Provider<List<Json>>((ref) {
  final actions = ref.watch(waitingActionsProvider);
  final offers = {
    for (final offer in ref.watch(snapshotListProvider('offers')))
      offer['id']: offer,
  };

  final drafts = [
    for (final action in actions)
      if (action.kind == 'reservation.create')
        {
          'local': true,
          'local_id': action.localId,
          'status': 'pending_sync',
          'offer_id': action.body!['offer_id'],
          'quantity': action.body!['quantity'],
          'offer_title': offers[action.body!['offer_id']]?['title'],
          'address': offers[action.body!['offer_id']]?['address'],
          'pickup_start': offers[action.body!['offer_id']]?['pickup_start'],
          'pickup_end': offers[action.body!['offer_id']]?['pickup_end'],
          'created_at': action.createdAt.toIso8601String(),
        },
  ];

  return [
    ...drafts,
    ...withPendingActions(
      ref.watch(snapshotListProvider('reservations')),
      actions,
      'reservation.',
    ),
  ];
});

/// Réservations reçues par le donateur.
final receivedReservationsProvider = Provider<List<Json>>((ref) {
  return withPendingActions(
    ref.watch(snapshotListProvider('received')),
    ref.watch(waitingActionsProvider),
    'reservation.',
  );
});

// ---------- Actions ----------

class ReservationsRepository {
  ReservationsRepository(this._sync, this._outbox);

  final SyncController _sync;
  final Future<void> Function(int localId) _outbox;

  /// Hors ligne, la réservation part en file : le serveur l'accepte ou la
  /// refuse (offre épuisée entre-temps) à la synchronisation.
  Future<SubmitResult> reserve({
    required int offerId,
    required String offerTitle,
    int quantity = 1,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'reservation.create',
        method: 'POST',
        path: ApiEndpoints.reservations,
        body: {'offer_id': offerId, 'quantity': quantity},
        label: 'Réservation de « $offerTitle »',
      ),
    );
  }

  Future<SubmitResult> confirm(Json reservation) {
    return _sync.submit(
      PendingAction(
        kind: 'reservation.confirm',
        method: 'PATCH',
        path: ApiEndpoints.confirmReservation(reservation['id'] as int),
        targetId: reservation['id'] as int,
        label: 'Confirmation pour ${reservation['beneficiary_name']}',
      ),
    );
  }

  /// Une réservation pas encore envoyée est simplement retirée de la file.
  Future<SubmitResult> cancel(Json reservation) async {
    if (reservation['local'] == true) {
      await _outbox(reservation['local_id'] as int);
      return const Sent();
    }
    return _sync.submit(
      PendingAction(
        kind: 'reservation.cancel',
        method: 'PATCH',
        path: ApiEndpoints.cancelReservation(reservation['id'] as int),
        targetId: reservation['id'] as int,
        label: 'Annulation de « ${reservation['offer_title']} »',
      ),
    );
  }

  /// Hors ligne, le code est vérifié par le serveur à la synchronisation ;
  /// un code faux revient en « Action refusée ».
  Future<SubmitResult> validatePickup(Json reservation, String pickupCode) {
    return _sync.submit(
      PendingAction(
        kind: 'reservation.pickup',
        method: 'POST',
        path: ApiEndpoints.pickup(reservation['id'] as int),
        body: {'pickup_code': pickupCode},
        targetId: reservation['id'] as int,
        label: 'Retrait de « ${reservation['offer_title']} »',
      ),
    );
  }
}

final reservationsRepositoryProvider = Provider<ReservationsRepository>(
  (ref) => ReservationsRepository(
    ref.read(syncControllerProvider.notifier),
    ref.read(outboxProvider).remove,
  ),
);
