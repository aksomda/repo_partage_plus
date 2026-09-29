import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/notifications/reminder_planner.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_service.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';

import 'helpers.dart';

Future<ResponseBody> networkDown(RequestOptions request) => throw DioException(
  requestOptions: request,
  type: DioExceptionType.connectionError,
);

Map<String, dynamic> offer({
  required int id,
  double lat = 12.3714,
  double lng = -1.5197,
  String status = 'published',
  int quantity = 5,
  Duration pickupEndIn = const Duration(hours: 5),
  int expiryInDays = 1,
}) {
  final now = DateTime.now();
  return {
    'id': id,
    'title': 'Offre $id',
    'status': status,
    'quantity_available': quantity,
    'latitude': lat,
    'longitude': lng,
    'pickup_end': now.add(pickupEndIn).toUtc().toIso8601String(),
    'expiry_date': now
        .add(Duration(days: expiryInDays))
        .toIso8601String()
        .substring(0, 10),
  };
}

void main() {
  group('offres à proximité calculées sur l’appareil', () {
    test('filtre les offres indisponibles et trie par distance', () {
      final offers = [
        offer(id: 1, lat: 12.39), // ~2 km
        offer(id: 2), // sur place
        offer(id: 3, lat: 12.50), // ~14 km : hors rayon
        offer(id: 4, status: 'pending'),
        offer(id: 5, quantity: 0),
        offer(id: 6, pickupEndIn: const Duration(hours: -1)),
        offer(id: 7, expiryInDays: -1),
      ];

      final result = nearbyOffers(
        offers,
        lat: 12.3714,
        lng: -1.5197,
        radiusKm: 5,
        now: DateTime.now(),
      );

      expect(result.map((o) => o['id']), [2, 1]);
      expect(result.last['distance_km'], closeTo(2.07, 0.05));
    });

    test('les réservations hors ligne réduisent la quantité affichée', () {
      final offers = applyPendingReservations(
        [offer(id: 1, quantity: 5)],
        [
          PendingAction(
            kind: 'reservation.create',
            method: 'POST',
            path: '/reservations',
            label: 'test',
            body: {'offer_id': 1, 'quantity': 2},
          ),
        ],
      );
      expect(offers.single['quantity_available'], 3);
    });
  });

  group('rappels programmés localement', () {
    test('rappel de retrait 2 h avant et alerte DLC la veille à 8 h', () {
      final now = DateTime(2026, 9, 24, 10);
      final planned = ReminderPlanner.plan(
        reservations: [
          {
            'id': 7,
            'status': 'confirmed',
            'offer_title': 'Pain',
            'address': 'Ici',
            'pickup_code': '123456',
            'pickup_start': DateTime(2026, 9, 24, 18).toUtc().toIso8601String(),
            'pickup_end': DateTime(2026, 9, 24, 20).toUtc().toIso8601String(),
            'expiry_date': '2026-09-26',
          },
          {
            'id': 8,
            'status': 'cancelled',
            'pickup_start': DateTime(2026, 9, 24, 18).toUtc().toIso8601String(),
            'pickup_end': DateTime(2026, 9, 24, 20).toUtc().toIso8601String(),
            'expiry_date': '2026-09-26',
          },
        ],
        myOffers: [
          {
            'id': 3,
            'status': 'published',
            'title': 'Yaourts',
            'quantity_available': 4,
            'expiry_date': '2026-09-25',
          },
        ],
        now: now,
      );

      final byId = {for (final p in planned) p.id: p};
      expect(byId.keys, {1000007, 2000007, 3000003});
      expect(byId[1000007]!.at, DateTime(2026, 9, 24, 16).toUtc());
      expect(byId[1000007]!.body, contains('123456'));
      expect(byId[2000007]!.at, DateTime(2026, 9, 25, 8).toUtc());
      expect(byId[3000003]!.at, DateTime(2026, 9, 24, 8).toUtc());
    });
  });

  group('file d’attente et synchronisation', () {
    late LocalStore store;
    late Outbox outbox;
    late FakeServer server;
    late SyncService sync;

    final snapshot = {
      'profile': {'id': 1, 'role': 'beneficiary'},
      'offers': <Object>[],
      'reservations': [
        {'id': 42, 'status': 'pending', 'pickup_code': '654321'},
      ],
      'notifications': <Object>[],
      'impact': {'pickups': 0},
    };

    PendingAction reservation() => PendingAction(
      kind: 'reservation.create',
      method: 'POST',
      path: '/reservations',
      label: 'Réservation de « Pain »',
      body: {'offer_id': 1, 'quantity': 2},
    );

    setUp(() async {
      store = await memoryStore();
      await store.saveToken('jeton');
      outbox = Outbox(store.db);
      server = FakeServer(networkDown);
      sync = SyncService(
        dio: Dio()..httpClientAdapter = server,
        store: store,
        outbox: outbox,
        notifications: LocalNotifications(),
      );
    });

    test(
      'hors ligne, l’action est gardée puis envoyée au retour du réseau',
      () async {
        final action = await outbox.add(reservation());

        final offline = await sync.sync();
        expect(offline.outcome, SyncOutcome.offline);
        expect((await outbox.all()).single.attempts, 1);

        server.handler = (request) async => request.method == 'GET'
            ? jsonResponse(200, snapshot)
            : jsonResponse(201, {'id': 42});

        final online = await sync.sync();
        expect(online.outcome, SyncOutcome.done);
        expect(online.sent, 1);
        expect(await outbox.all(), isEmpty);

        final post = server.requests.lastWhere((r) => r.method == 'POST');
        expect(post.headers['Idempotency-Key'], action.key);

        final reservations = await store.readSnapshot('reservations') as List;
        expect(reservations.single['pickup_code'], '654321');
      },
    );

    test('un refus du serveur est gardé, signalé et jamais renvoyé', () async {
      await outbox.add(reservation());
      server.handler = (request) async => request.method == 'GET'
          ? jsonResponse(200, snapshot)
          : jsonResponse(409, {'error': 'Offre indisponible'});

      final report = await sync.sync();
      expect(report.rejected.single.error, 'Offre indisponible');
      expect((await outbox.all()).single.isRejected, isTrue);

      final posts = server.requests.where((r) => r.method == 'POST').length;
      await sync.sync();
      expect(server.requests.where((r) => r.method == 'POST').length, posts);

      await outbox.clearRejected();
      expect(await outbox.all(), isEmpty);
    });

    test('l’ordre est respecté : on s’arrête à la première coupure', () async {
      await outbox.add(reservation());
      await outbox.add(reservation());
      var calls = 0;
      server.handler = (request) async {
        calls++;
        if (calls == 1) return jsonResponse(201, {'id': 1});
        return networkDown(request);
      };

      final report = await sync.sync();
      expect(report.outcome, SyncOutcome.offline);
      expect(report.sent, 1);
      expect(await outbox.all(), hasLength(1));
    });

    test('sans session, rien n’est envoyé', () async {
      await store.clear();
      await outbox.add(reservation());
      expect((await sync.sync()).outcome, SyncOutcome.loggedOut);
      expect(server.requests, isEmpty);
    });
  });
}
