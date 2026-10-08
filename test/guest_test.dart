import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';

import 'helpers.dart';

const guest = GuestIdentity(
  firstName: 'Moussa',
  lastName: 'Kaboré',
  phone: '+226 76 11 22 33',
);

void main() {
  late LocalStore store;
  late FakeServer server;
  late FakeLocation location;
  late ProviderContainer container;

  setUp(() async {
    store = await memoryStore();
    location = FakeLocation();
    server = FakeServer((request) async => jsonResponse(404, {}));
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        locationGatewayProvider.overrideWith((ref) => location),
        dioProvider.overrideWithValue(Dio()..httpClientAdapter = server),
      ],
    );
    addTearDown(container.dispose);
  });

  group('point de départ', () {
    test('position actuelle autorisée : utilisée et mémorisée', () async {
      final origin = container.read(originProvider.notifier);
      expect(await origin.useCurrentPosition(), isTrue);

      final state = container.read(originProvider);
      expect(state.place!.isCurrent, isTrue);
      expect(state.error, isNull);
      expect((await store.readSetting<Map>('origin'))!['lat'], 12.3714);
    });

    test('refus : message, point précédent conservé', () async {
      final origin = container.read(originProvider.notifier);
      await origin.choose(const Place(lat: 12.4, lng: -1.5, label: 'Gounghin'));
      location = FakeLocation(
        failure: const LocationFailure('Refusé', canOpenSettings: true),
      );
      container.invalidate(locationGatewayProvider);

      expect(await origin.useCurrentPosition(), isFalse);
      final state = container.read(originProvider);
      expect(state.place!.label, 'Gounghin');
      expect(state.error!.canOpenSettings, isTrue);
    });
  });

  group('filtres', () {
    final offers = [
      publishedOffer(id: 1, title: 'Panier de mangues'),
      publishedOffer(id: 2, title: 'Pains du jour', lat: 12.40, categoryId: 2),
      publishedOffer(id: 3, title: 'Mangues séchées', lat: 12.80),
    ];
    const here = Place(lat: 12.3714, lng: -1.5197, label: 'Ici');

    test('rayon, texte et catégorie', () {
      expect(
        filterOffers(
          offers,
          here,
          const OfferFilters(radiusKm: 5),
        ).map((offer) => offer['id']),
        [1, 2],
      );
      expect(
        filterOffers(
          offers,
          here,
          const OfferFilters(text: 'mangue', radiusKm: 50),
        ).map((offer) => offer['id']),
        [1, 3],
      );
      expect(
        filterOffers(
          offers,
          here,
          const OfferFilters(categoryId: 2),
        ).map((offer) => offer['id']),
        [2],
      );
    });

    test('mes offres / des autres', () {
      final mine = [
        offers[0],
        // En attente de validation et loin : affichée quand même.
        {
          ...publishedOffer(id: 9, title: 'Jus', lat: 13.5),
          'status': 'pending',
        },
      ];
      List<Object?> ids(OfferOwner owner) => filterOffersByOwner(
        available: offers,
        mine: mine,
        origin: here,
        filters: OfferFilters(radiusKm: 50, owner: owner),
      ).map((offer) => offer['id']).toList();

      expect(ids(OfferOwner.all), [1, 2, 3]);
      expect(ids(OfferOwner.mine), [1, 9]);
      expect(ids(OfferOwner.others), [2, 3]);
    });

    test('sans point de départ : toutes les offres, sans distance', () {
      final result = filterOffers(offers, null, const OfferFilters());
      expect(result, hasLength(3));
      expect(result.first.containsKey('distance_km'), isFalse);
    });
  });

  group('invité', () {
    GuestRepository repository() => container.read(guestRepositoryProvider);
    Map<String, dynamic> bodyOf(RequestOptions request) =>
        jsonDecode(jsonEncode(request.data)) as Map<String, dynamic>;

    test(
      'publication : identité envoyée, jeton gardé sur l’appareil',
      () async {
        server.handler = (request) async => jsonResponse(201, {
          'id': 12,
          'title': 'Pains',
          'status': 'pending',
          'guest_token': 'jeton-offre',
        });

        await repository().publishOffer({'title': 'Pains'}, guest);

        expect(bodyOf(server.requests.single)['guest'], guest.toMap());
        final saved = await store.readGuestItems('offers');
        expect(saved.single['guest_token'], 'jeton-offre');
        expect(
          (await store.readSetting<Map>('guest_identity'))!['phone'],
          guest.phone,
        );
      },
    );

    test(
      'réservation payante : référence envoyée, suivi et annulation par jeton',
      () async {
        server.handler = (request) async {
          if (request.method == 'POST') {
            return jsonResponse(201, {
              'id': 30,
              'status': 'pending',
              'pickup_code': '123456',
              'guest_token': 'jeton-resa',
            });
          }
          if (request.method == 'GET') {
            return jsonResponse(200, {'id': 30, 'status': 'confirmed'});
          }
          return jsonResponse(200, {'id': 30, 'status': 'cancelled'});
        };

        final created = await repository().reserve(
          offerId: 1,
          quantity: 2,
          paymentReference: 'OM123456',
          guest: guest,
        );
        expect(bodyOf(server.requests.first)['payment_reference'], 'OM123456');
        expect(created['pickup_code'], '123456');

        await repository().refresh();
        final refreshed = server.requests.last;
        expect(refreshed.path, '/reservations/guest/30');
        expect(refreshed.headers['X-Guest-Token'], 'jeton-resa');
        expect(
          (await store.readGuestItems('reservations')).single['status'],
          'confirmed',
        );

        final reservation = (await store.readGuestItems('reservations')).single;
        await repository().cancelReservation(reservation);
        final saved = (await store.readGuestItems('reservations')).single;
        expect(saved['status'], 'cancelled');
        // Le jeton reste disponible après la mise à jour.
        expect(saved['guest_token'], 'jeton-resa');
      },
    );

    test('hors ligne : message clair', () async {
      server.handler = networkDown;
      await expectLater(
        repository().reserve(offerId: 1, quantity: 1, guest: guest),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            startsWith('Serveur injoignable'),
          ),
        ),
      );
    });
  });
}
