import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';

/// Offre disponible et réservable à l'instant [now] (mêmes règles que le serveur).
bool isOfferAvailable(Json offer, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return offer['status'] == 'published' &&
      (offer['quantity_available'] as int) > 0 &&
      DateTime.parse(offer['pickup_end'] as String).isAfter(now) &&
      !DateTime.parse(offer['expiry_date'] as String).isBefore(today);
}

/// Offre publiée sans compte : pas de réservation, on appelle le donateur.
bool isGuestOffer(Json offer) =>
    offer['is_guest'] == 1 || offer['is_guest'] == true;

/// Retire des quantités affichées ce que l'utilisateur a réservé hors ligne.
List<Json> applyPendingReservations(
  List<Json> offers,
  List<PendingAction> actions,
) {
  final reserved = <int, int>{};
  for (final action in actions) {
    if (action.kind != 'reservation.create') continue;
    final offerId = action.body!['offer_id']! as int;
    reserved[offerId] =
        (reserved[offerId] ?? 0) + (action.body!['quantity']! as int);
  }

  return [
    for (final offer in offers)
      {
        ...offer,
        'quantity_available':
            (offer['quantity_available'] as int) - (reserved[offer['id']] ?? 0),
      },
  ];
}

/// Offres à moins de [radiusKm] de ([lat], [lng]), triées par distance.
/// Calculé sur l'appareil : fonctionne à l'identique en ligne et hors ligne.
List<Json> nearbyOffers(
  List<Json> offers, {
  required double lat,
  required double lng,
  required double radiusKm,
  required DateTime now,
}) {
  const distance = Distance(roundResult: false);
  final origin = LatLng(lat, lng);

  final result = <Json>[];
  for (final offer in offers) {
    if (!isOfferAvailable(offer, now)) continue;

    final km =
        distance(
          origin,
          LatLng(
            (offer['latitude'] as num).toDouble(),
            (offer['longitude'] as num).toDouble(),
          ),
        ) /
        1000;
    if (km <= radiusKm) result.add({...offer, 'distance_km': km});
  }

  result.sort(
    (a, b) =>
        (a['distance_km'] as double).compareTo(b['distance_km'] as double),
  );
  return result;
}

// ---------- Lecture (toujours depuis les données locales) ----------

/// Offres disponibles, quantités corrigées des réservations hors ligne.
final availableOffersProvider = Provider<List<Json>>((ref) {
  final offers = applyPendingReservations(
    ref.watch(snapshotListProvider('offers')),
    ref.watch(waitingActionsProvider),
  );
  final now = DateTime.now();
  return offers.where((offer) => isOfferAvailable(offer, now)).toList();
});

class NearbyQuery {
  const NearbyQuery(this.lat, this.lng, {this.radiusKm = 5});

  final double lat;
  final double lng;
  final double radiusKm;

  @override
  bool operator ==(Object other) =>
      other is NearbyQuery &&
      other.lat == lat &&
      other.lng == lng &&
      other.radiusKm == radiusKm;

  @override
  int get hashCode => Object.hash(lat, lng, radiusKm);
}

final nearbyOffersProvider = Provider.family<List<Json>, NearbyQuery>((
  ref,
  query,
) {
  return nearbyOffers(
    ref.watch(availableOffersProvider),
    lat: query.lat,
    lng: query.lng,
    radiusKm: query.radiusKm,
    now: DateTime.now(),
  );
});

/// Offres dont la DLC tombe dans les [days] prochains jours.
final expiringOffersProvider = Provider.family<List<Json>, int>((ref, days) {
  final limit = DateTime.now().add(Duration(days: days));
  return ref
      .watch(availableOffersProvider)
      .where(
        (offer) =>
            !DateTime.parse(offer['expiry_date'] as String).isAfter(limit),
      )
      .toList();
});

/// Détail d'une offre : copie locale si elle existe, sinon lecture sur l'API
/// (offre d'invité encore en modération : lue avec son jeton).
final offerDetailProvider = FutureProvider.autoDispose.family<Json, int>((
  ref,
  offerId,
) async {
  final local = [
    ...ref.watch(snapshotListProvider('offers')),
    ...ref.watch(snapshotListProvider('my_offers')),
  ].where((offer) => offer['id'] == offerId).firstOrNull;
  if (local != null) return local;

  final guest = (ref.watch(guestOffersProvider).value ?? const <Json>[])
      .where((offer) => offer['id'] == offerId)
      .firstOrNull;
  try {
    final response = await ref
        .read(dioProvider)
        .get<Map<String, dynamic>>(
          ApiEndpoints.offer(offerId),
          options: guest == null
              ? null
              : Options(headers: {'X-Guest-Token': guest['guest_token']}),
        );
    return response.data!;
  } on DioException catch (error) {
    if (guest != null && error.response == null) return guest;
    if (error.response == null) {
      throw ApiException('Offre introuvable hors ligne : reconnectez-vous');
    }
    throw ApiException.fromDio(error);
  }
});

/// Risque de gaspillage et suggestions, par id d'offre du donateur
/// (calculés par le serveur, copiés à chaque synchronisation).
final offerInsightsProvider = Provider<Map<Object?, Json>>(
  (ref) => {
    for (final insight in ref.watch(snapshotListProvider('offer_insights')))
      insight['offer_id']: insight,
  },
);

final categoriesProvider = Provider<List<Json>>(
  (ref) => ref.watch(snapshotListProvider('categories')),
);

/// Offres du donateur, y compris celles publiées hors ligne (`local: true`).
final myOffersProvider = Provider<List<Json>>((ref) {
  final actions = ref.watch(waitingActionsProvider);
  final drafts = [
    for (final action in actions)
      if (action.kind == 'offer.create')
        {
          ...?action.body,
          'local': true,
          'local_id': action.localId,
          'status': 'pending_sync',
        },
  ];
  return [
    ...drafts,
    ...withPendingActions(
      ref.watch(snapshotListProvider('my_offers')),
      actions,
      'offer.',
    ),
  ];
});

// ---------- Actions (mises en file si hors ligne) ----------

class OffersRepository {
  OffersRepository(this._sync);

  final SyncController _sync;

  /// [offer] : champs attendus par POST /api/offers (voir server/README.md).
  Future<SubmitResult> create(Map<String, Object?> offer) {
    return _sync.submit(
      PendingAction(
        kind: 'offer.create',
        method: 'POST',
        path: ApiEndpoints.offers,
        body: offer,
        label: 'Publication de « ${offer['title']} »',
      ),
    );
  }

  Future<SubmitResult> update(int offerId, Map<String, Object?> offer) {
    return _sync.submit(
      PendingAction(
        kind: 'offer.update',
        method: 'PUT',
        path: ApiEndpoints.offer(offerId),
        body: offer,
        targetId: offerId,
        label: 'Modification de « ${offer['title']} »',
      ),
    );
  }

  /// Créneaux d'une offre publiée, réservée ou non (voir PATCH /slots).
  Future<SubmitResult> updateSlots(
    int offerId,
    String title,
    List<Map<String, Object?>> slots,
  ) {
    return _sync.submit(
      PendingAction(
        kind: 'offer.slots',
        method: 'PATCH',
        path: ApiEndpoints.offerSlots(offerId),
        body: {'slots': slots},
        targetId: offerId,
        label: 'Créneaux de « $title »',
      ),
    );
  }

  Future<SubmitResult> withdraw(int offerId, String title) {
    return _sync.submit(
      PendingAction(
        kind: 'offer.withdraw',
        method: 'DELETE',
        path: ApiEndpoints.offer(offerId),
        targetId: offerId,
        label: 'Retrait de « $title »',
      ),
    );
  }
}

final offersRepositoryProvider = Provider<OffersRepository>(
  (ref) => OffersRepository(ref.read(syncControllerProvider.notifier)),
);
