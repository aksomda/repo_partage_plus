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
    required GuestIdentity guest,
  }) async {
    final created = await _send(
      () => _dio.post<Map<String, dynamic>>(
        ApiEndpoints.reservations,
        data: {
          'offer_id': offerId,
          'quantity': quantity,
          'payment_reference': ?paymentReference,
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
  Future<void> refresh() async {
    for (final offer in await _store.readGuestItems('offers')) {
      await _refreshOne(
        'offers',
        offer,
        ApiEndpoints.offer(offer['id']! as int),
      );
    }
    for (final reservation in await _store.readGuestItems('reservations')) {
      await _refreshOne(
        'reservations',
        reservation,
        ApiEndpoints.guestReservation(reservation['id']! as int),
      );
    }
  }

  Future<void> _refreshOne(String kind, Json item, String path) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        path,
        options: _auth(item),
      );
      await _store.saveGuestItem(kind, {
        ...response.data!,
        'guest_token': item['guest_token'],
      });
    } on DioException catch (error) {
      // Offre retirée ou expirée côté serveur : on garde la dernière copie.
      if (error.response?.statusCode == 404) {
        await _store.saveGuestItem(kind, {...item, 'status': 'unavailable'});
      }
    }
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
        throw ApiException('Connexion Internet requise');
      }
      throw ApiException.fromDio(error);
    }
  }
}

final guestRepositoryProvider = Provider<GuestRepository>(GuestRepository.new);
