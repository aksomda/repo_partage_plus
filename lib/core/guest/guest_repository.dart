import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

/// Identité saisie par une personne sans compte.
class GuestIdentity {
  const GuestIdentity({
    required this.firstName,
    required this.lastName,
    required this.phone,
  });

  final String firstName;
  final String lastName;
  final String phone;

  Map<String, Object?> toMap() => {
    'first_name': firstName,
    'last_name': lastName,
    'phone': phone,
  };

  static GuestIdentity? fromMap(Object? value) {
    if (value is! Map) return null;
    return GuestIdentity(
      firstName: value['first_name'] as String? ?? '',
      lastName: value['last_name'] as String? ?? '',
      phone: value['phone'] as String? ?? '',
    );
  }
}

/// Dernière identité utilisée, pour pré-remplir les formulaires.
final guestIdentityProvider = FutureProvider.autoDispose<GuestIdentity?>(
  (ref) async => GuestIdentity.fromMap(
    await ref.read(localStoreProvider).readSetting<Object?>('guest_identity'),
  ),
);

/// Publications faites sans compte sur cet appareil.
final guestOffersProvider = StreamProvider<List<Json>>(
  (ref) =>
      ref.watch(localStoreProvider).watchGuestItems('offers').map(asJsonList),
);

/// Réservations faites sans compte sur cet appareil.
final guestReservationsProvider = StreamProvider<List<Json>>(
  (ref) => ref
      .watch(localStoreProvider)
      .watchGuestItems('reservations')
      .map(asJsonList),
);

/// Publication et réservation sans compte. Les envois partent tout de suite
/// (connexion requise) : le serveur renvoie un jeton gardé sur l'appareil,
/// qui permet ensuite de suivre ou d'annuler depuis cet appareil seulement.
class GuestRepository {
  GuestRepository(this._ref);

  final Ref _ref;

  Dio get _dio => _ref.read(dioProvider);
  LocalStore get _store => _ref.read(localStoreProvider);

  Future<Json> publishOffer(
    Map<String, Object?> offer,
    GuestIdentity guest,
  ) async {
    final created = await _send(
      () => _dio.post<Map<String, dynamic>>(
        ApiEndpoints.offers,
        data: {...offer, 'guest': guest.toMap()},
      ),
    );
    await _remember(guest);
    await _store.saveGuestItem('offers', created);
    return created;
  }

  Future<Json> reserve({
    required int offerId,
    required int quantity,
    String? paymentReference,
    int? slotId,
    required GuestIdentity guest,
  }) async {
    final created = await _send(
      () => _dio.post<Map<String, dynamic>>(
        ApiEndpoints.reservations,
        data: {
          'offer_id': offerId,
          'quantity': quantity,
          'payment_reference': ?paymentReference,
          'slot_id': ?slotId,
          'guest': guest.toMap(),
        },
      ),
    );
    await _remember(guest);
    await _store.saveGuestItem('reservations', created);
    return created;
  }

  /// Relit sur le serveur l'état des publications et réservations locales.
  /// Silencieux hors ligne : les copies locales restent affichées.
  Future<void> refresh() => refreshGuestItems(_dio, _store);

  /// Modifie une publication faite sans compte (jeton de l'appareil).
  Future<Json> updateOffer(Json offer, Map<String, Object?> changes) async {
    final updated = await _send(
      () => _dio.put<Map<String, dynamic>>(
        ApiEndpoints.offer(offer['id'] as int),
        data: changes,
        options: _auth(offer),
      ),
    );
    await _store.saveGuestItem('offers', {
      ...updated,
      'guest_token': offer['guest_token'],
    });
    return updated;
  }

  /// Créneaux d'une publication faite sans compte, réservée ou non.
  Future<Json> updateOfferSlots(
    Json offer,
    List<Map<String, Object?>> slots,
  ) async {
    final updated = await _send(
      () => _dio.patch<Map<String, dynamic>>(
        ApiEndpoints.offerSlots(offer['id'] as int),
        data: {'slots': slots},
        options: _auth(offer),
      ),
    );
    await _store.saveGuestItem('offers', {
      ...updated,
      'guest_token': offer['guest_token'],
    });
    return updated;
  }

  Future<void> withdrawOffer(Json offer) async {
    await _send(
      () => _dio.delete<void>(
        ApiEndpoints.offer(offer['id'] as int),
        options: _auth(offer),
      ),
    );
    await _store.saveGuestItem('offers', {...offer, 'status': 'cancelled'});
  }

  Future<void> cancelReservation(Json reservation) async {
    final updated = await _send(
      () => _dio.patch<Map<String, dynamic>>(
        ApiEndpoints.cancelReservation(reservation['id'] as int),
        options: _auth(reservation),
      ),
    );
    await _store.saveGuestItem('reservations', {
      ...updated,
      'guest_token': reservation['guest_token'],
    });
  }

  Options _auth(Json item) =>
      Options(headers: {'X-Guest-Token': item['guest_token']});

  Future<void> _remember(GuestIdentity guest) =>
      _store.saveSetting('guest_identity', guest.toMap());

  Future<Json> _send<T>(Future<Response<T>> Function() request) async {
    try {
      final response = await request();
      final data = response.data;
      return data is Map ? Map<String, dynamic>.from(data) : const {};
    } on DioException catch (error) {
      if (error.response == null) {
        throw ApiException.unreachable();
      }
      throw ApiException.fromDio(error);
    }
  }
}

final guestRepositoryProvider = Provider<GuestRepository>(GuestRepository.new);

/// Statuts définitifs : plus rien ne peut changer, l'élément n'est plus
/// relu (sinon chaque synchronisation relirait tout l'historique).
const _finishedGuestStatuses = {
  'picked_up',
  'completed',
  'cancelled',
  'expired',
  'rejected',
  'unavailable',
};

/// Relit sur le serveur l'état des publications et réservations faites sans
/// compte sur cet appareil (aussi lancé à chaque synchronisation, pour
/// prévenir l'invité d'une confirmation ou d'une annulation). Silencieux
/// hors ligne : les copies locales restent affichées.
Future<void> refreshGuestItems(Dio dio, LocalStore store) async {
  for (final offer in await store.readGuestItems('offers')) {
    if (_finishedGuestStatuses.contains(offer['status'])) continue;
    await _refreshGuestItem(
      dio,
      store,
      'offers',
      offer,
      ApiEndpoints.offer(offer['id']! as int),
    );
  }
  for (final reservation in await store.readGuestItems('reservations')) {
    if (_finishedGuestStatuses.contains(reservation['status'])) continue;
    await _refreshGuestItem(
      dio,
      store,
      'reservations',
      reservation,
      ApiEndpoints.guestReservation(reservation['id']! as int),
    );
  }
}

Future<void> _refreshGuestItem(
  Dio dio,
  LocalStore store,
  String kind,
  Json item,
  String path,
) async {
  try {
    final response = await dio.get<Map<String, dynamic>>(
      path,
      options: Options(headers: {'X-Guest-Token': item['guest_token']}),
    );
    // Champs propres à l'appareil (jeton, dernier statut signalé) gardés.
    await store.patchGuestItem(kind, item['id'], {
      ...response.data!,
      'guest_token': item['guest_token'],
    });
  } on DioException catch (error) {
    // Offre retirée ou expirée côté serveur : on garde la dernière copie.
    if (error.response?.statusCode == 404) {
      await store.patchGuestItem(kind, item['id'], {'status': 'unavailable'});
    }
  }
}
