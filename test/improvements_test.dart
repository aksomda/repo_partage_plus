import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/offline/offline_banner.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/offline/sync_service.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/favorites/data/favorites.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';
import 'package:repo_partage_plus/features/reservations/presentation/my_reservations_screen.dart';

import 'helpers.dart';

String _day(int fromToday) => DateTime.now()
    .add(Duration(days: fromToday))
    .toIso8601String()
    .substring(0, 10);

void main() {
  group('filtres de la liste', () {
    final offers = [
      {...publishedOffer(id: 1, title: 'Pain', price: 0)},
      {
        ...publishedOffer(id: 2, title: 'Riz', price: 500),
        'expiry_date': _day(0),
      },
      {
        ...publishedOffer(id: 3, title: 'Mangues', price: 200),
        'expiry_date': _day(5),
      },
    ];

    List<Object?> ids(OfferFilters filters) =>
        filterOffers(offers, null, filters).map((o) => o['id']).toList();

    test('gratuit / prix réduit', () {
      expect(ids(const OfferFilters(price: PriceFilter.free)), [1]);
      expect(ids(const OfferFilters(price: PriceFilter.paid)), [2, 3]);
    });

    test('à sauver vite : date limite aujourd’hui ou demain', () {
      expect(ids(const OfferFilters(urgentOnly: true)), [1, 2]);
    });

    test('tri par prix puis par date limite', () {
      expect(ids(const OfferFilters(sort: OfferSort.price)), [1, 3, 2]);
      expect(ids(const OfferFilters(sort: OfferSort.expiry)), [2, 1, 3]);
    });

    test('mémorisés sur l’appareil, sauf le texte', () {
      const filters = OfferFilters(
        text: 'pain',
        categoryId: 3,
        radiusKm: 25,
        price: PriceFilter.paid,
        urgentOnly: true,
        sort: OfferSort.expiry,
      );
      final restored = OfferFilters.fromMap(filters.toMap());
      expect(restored.text, isEmpty);
      expect(restored.toMap(), filters.toMap());
    });

    test('rayon enregistré ramené au rayon proposé le plus proche', () {
      expect(nearestRadius(7), 5);
      expect(nearestRadius(40), 50);
    });

    test('rayon illimité par défaut, sans limite de distance', () {
      expect(const OfferFilters().radiusKm, unlimitedRadius);
      expect(radiusLabel(unlimitedRadius), 'Illimité');
      expect(radiusLabel(25), '25 km');
      expect(nearestRadius(unlimitedRadius), unlimitedRadius);
      // Ancien rayon mémorisé (10 km par défaut) : plus repris.
      expect(OfferFilters.fromMap({'radius_km': 10}).radiusKm, unlimitedRadius);
      expect(
        OfferFilters.fromMap(const OfferFilters().toMap()).radiusKm,
        unlimitedRadius,
      );

      // Offre à ~1 100 km : trouvée sans limite, pas avec 250 km.
      final far = [
        {
          'id': 1,
          'status': 'published',
          'quantity_available': 1,
          'latitude': 22.0,
          'longitude': -1.5,
          'expiry_date': '2999-01-01',
          'pickup_end': '2999-01-01T00:00:00Z',
        },
      ];
      final now = DateTime.now();
      expect(
        nearbyOffers(far, lat: 12.37, lng: -1.52, radiusKm: 250, now: now),
        isEmpty,
      );
      expect(
        nearbyOffers(
          far,
          lat: 12.37,
          lng: -1.52,
          radiusKm: unlimitedRadius,
          now: now,
        ),
        hasLength(1),
      );

      // Recherche enregistrée illimitée : null en JSON, relue illimitée.
      const search = SavedSearch(name: 'Partout');
      expect(search.toMap()['radius_km'], isNull);
      expect(SavedSearch.fromMap(search.toMap())!.radiusKm, unlimitedRadius);
    });
  });

  group('recherches enregistrées', () {
    test('prix et urgence conservés', () {
      const search = SavedSearch(
        name: 'Gratuit',
        price: PriceFilter.free,
        urgentOnly: true,
      );
      final restored = SavedSearch.fromMap(search.toMap())!;
      expect(restored.price, PriceFilter.free);
      expect(restored.urgentOnly, isTrue);
    });

    test('suggestions prêtes sans compte', () {
      expect(suggestedSearches, isNotEmpty);
      final applied = const OfferFilters().withSearch(suggestedSearches.first);
      expect(applied.price, PriceFilter.free);
      expect(applied.radiusKm, 5);
    });

    test('fusion appareil + compte : rien n’est perdu', () {
      const device = Favorites(
        offerIds: {1},
        searches: [SavedSearch(name: 'Pain', text: 'pain')],
      );
      const account = Favorites(
        offerIds: {2},
        searches: [
          SavedSearch(name: 'pain', text: 'baguette'),
          SavedSearch(name: 'Riz', text: 'riz'),
        ],
      );
      final merged = device.mergedWith(account);
      expect(merged.offerIds, {1, 2});
      // Même nom : celle de l'appareil gagne.
      expect(merged.searches.map((s) => s.text), ['pain', 'riz']);
    });

    test('alertes : seulement les nouvelles offres, pas les siennes', () {
      final now = DateTime.now();
      final offers = [
        publishedOffer(id: 1, title: 'Pain du matin'),
        publishedOffer(id: 2, title: 'Pain de mie'),
        publishedOffer(id: 3, title: 'Pain complet'),
        publishedOffer(id: 4, title: 'Riz'),
        publishedOffer(id: 5, title: 'Pain lointain', lat: 14, lng: 2),
      ];
      final matches = newOfferMatches(
        offers: offers,
        seen: {1},
        searches: const [SavedSearch(name: 'Pain', text: 'pain', radiusKm: 5)],
        now: now,
        origin: const Place(lat: 12.3714, lng: -1.5197, label: 'Ici'),
        ownIds: {3},
      );
      expect(matches.map((m) => m.$1['id']), [2]);
      expect(matches.single.$2.name, 'Pain');
    });
  });

  test('réservation sans compte : changement de statut retenu', () async {
    final store = await memoryStore();
    final notifications = LocalNotifications();
    await store.saveGuestItem('reservations', {
      'id': 12,
      'status': 'pending',
      'offer_title': 'Pain',
    });
    await notifications.showGuestReservationChanges(store);
    expect(
      (await store.readGuestItems('reservations')).single['notified_status'],
      'pending',
    );

    await store.patchGuestItem('reservations', 12, {'status': 'confirmed'});
    await notifications.showGuestReservationChanges(store);
    expect(
      (await store.readGuestItems('reservations')).single['notified_status'],
      'confirmed',
    );
  });

  group('dates de publication', () {
    final now = DateTime(2026, 10, 5, 20);
    final tomorrow = DateTime(2026, 10, 6);

    test('retrait déjà terminé : refusé', () {
      expect(
        pickupDatesError([DateTime(2026, 10, 5, 18)], tomorrow, now: now),
        contains('dans le futur'),
      );
    });

    test('retrait après la date limite : refusé', () {
      expect(
        pickupDatesError([DateTime(2026, 10, 7, 9)], tomorrow, now: now),
        contains('date limite'),
      );
    });

    test('retrait le jour de la date limite : accepté', () {
      expect(
        pickupDatesError([DateTime(2026, 10, 6, 23)], tomorrow, now: now),
        isNull,
      );
    });
  });

  group('historique des réservations', () {
    final now = DateTime(2026, 10, 5);
    final reservations = [
      {'id': 1, 'status': 'pending', 'created_at': '2026-10-04T10:00:00Z'},
      {'id': 2, 'status': 'picked_up', 'created_at': '2026-09-01T10:00:00Z'},
      {'id': 3, 'status': 'cancelled', 'created_at': '2026-10-01T10:00:00Z'},
      {'id': 4, 'status': 'pending_sync'},
    ];
    List<Object?> ids(HistoryStatus status, HistoryPeriod period) =>
        filterHistory(
          reservations,
          status,
          period,
          now: now,
        ).map((r) => r['id']).toList();

    test('par statut', () {
      expect(ids(HistoryStatus.active, HistoryPeriod.all), [1, 4]);
      expect(ids(HistoryStatus.pickedUp, HistoryPeriod.all), [2]);
      expect(ids(HistoryStatus.cancelled, HistoryPeriod.all), [3]);
    });

    test('par période : sans date (hors ligne) comptée comme récente', () {
      expect(ids(HistoryStatus.all, HistoryPeriod.week), [1, 3, 4]);
      expect(ids(HistoryStatus.all, HistoryPeriod.month), [1, 3, 4]);
    });
  });

  test('invité : les éléments terminés ne sont plus relus', () async {
    final store = await memoryStore();
    await store.saveGuestItem('reservations', {
      'id': 1,
      'status': 'picked_up',
      'guest_token': 't1',
    });
    await store.saveGuestItem('reservations', {
      'id': 2,
      'status': 'pending',
      'guest_token': 't2',
    });
    final server = FakeServer(
      (request) async => jsonResponse(200, {'id': 2, 'status': 'confirmed'}),
    );
    final dio = Dio()..httpClientAdapter = server;

    await refreshGuestItems(dio, store);

    expect(server.requests.map((r) => r.path), ['/reservations/guest/2']);
    final items = await store.readGuestItems('reservations');
    expect(items.firstWhere((r) => r['id'] == 2)['status'], 'confirmed');
  });

  test('préférences de recommandation : le compte fait foi', () async {
    final store = await memoryStore();
    Future<void> account(double km) => store.saveSnapshot({
      'profile': {
        'id': 4,
        'role': 'beneficiary',
        'preferences': {
          'reco': {'max_distance_km': km},
        },
      },
    });
    await account(7);
    final container = ProviderContainer(
      overrides: [
        ...await testOverrides(store: store),
        initialTokenProvider.overrideWithValue('jwt'),
      ],
    );
    addTearDown(container.dispose);
    container.listen(recoPreferencesProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(recoPreferencesProvider).maxDistanceKm, 7);

    // Réglage changé sur un autre appareil : repris ici.
    await account(12);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(recoPreferencesProvider).maxDistanceKm, 12);
  });

  testWidgets('accueil : compteurs de la plateforme, même sans compte', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(() async {
      final store = await memoryStore();
      await store.saveSnapshot({
        'public_impact': {
          'food_kg': 1250.4,
          'meals': 3126,
          'co2_kg': 2100,
          'users': 87,
        },
      });
      return store;
    }))!;
    final overrides = (await tester.runAsync(
      () => testOverrides(store: store),
    ))!;
    final router = createRouter(initialLocation: AppRoutes.home);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ensemble, nous avons déjà sauvé :'), findsOneWidget);
    // Milliers séparés par une espace insécable (formatNumber).
    expect(find.textContaining(RegExp(r'^3\D126 repas$')), findsOneWidget);
    expect(find.text('87 membres'), findsOneWidget);
  });

  testWidgets('carte : mêmes filtres que la liste', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(() async {
      final store = await memoryStore();
      await store.saveSnapshot({
        'offers': [publishedOffer(id: 1, title: 'Riz', price: 500)],
      });
      await store.saveSetting('origin', {
        'lat': 12.3714,
        'lng': -1.5197,
        'label': 'Ici',
      });
      await store.saveSetting('offer_filters', {'price': 'free'});
      return store;
    }))!;
    final overrides = (await tester.runAsync(
      () => testOverrides(store: store),
    ))!;
    final router = createRouter(initialLocation: AppRoutes.nearbyMap);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Filtre « Gratuit » mémorisé : l'offre payante n'est pas sur la carte.
    expect(find.textContaining('ne correspond aux filtres'), findsOneWidget);
    await tester.tap(find.text('Effacer les filtres'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('ne correspond aux filtres'), findsNothing);
  });

  testWidgets('session refusée : bandeau « Se reconnecter »', (tester) async {
    final overrides = (await tester.runAsync(() => testOverrides()))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          syncControllerProvider.overrideWith(_RefusedSync.new),
        ],
        child: const MaterialApp(home: OfflineBanner(child: SizedBox.shrink())),
      ),
    );
    await tester.pump();

    expect(
      find.text('Session refusée par le serveur : reconnectez-vous'),
      findsOneWidget,
    );
    expect(find.text('Se reconnecter'), findsOneWidget);
  });

  testWidgets('bénéficiaire qui publie : onglet « Commandes reçues »', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = (await tester.runAsync(() async {
      final store = await memoryStore();
      await store.saveSnapshot({
        'profile': {'id': 4, 'name': 'Awa', 'role': 'beneficiary'},
        'my_offers': [
          {...publishedOffer(id: 7, title: 'Sac d’oignons'), 'donor_id': 4},
        ],
        'received': [
          {
            'id': 30,
            'offer_id': 7,
            'offer_title': 'Sac d’oignons',
            'status': 'pending',
            'quantity': 1,
            'unit': 'sac',
            'beneficiary_name': 'Issa',
            'pickup_start': DateTime.now().toUtc().toIso8601String(),
            'pickup_end': DateTime.now()
                .add(const Duration(hours: 3))
                .toUtc()
                .toIso8601String(),
          },
        ],
      });
      return store;
    }))!;
    final overrides = (await tester.runAsync(
      () => testOverrides(store: store),
    ))!;
    final router = createRouter(initialLocation: AppRoutes.myReservations);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          initialTokenProvider.overrideWithValue('jwt-awa'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Commandes reçues'), findsOneWidget);
    expect(find.text('Mes réservations'), findsOneWidget);
  });
}

/// Dernière synchronisation refusée par le serveur (401).
class _RefusedSync extends SyncController {
  @override
  SyncState build() =>
      const SyncState(online: true, lastOutcome: SyncOutcome.unauthorized);
}
