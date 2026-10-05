import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/favorites/data/favorites.dart';
import 'package:repo_partage_plus/features/impact/domain/impact_csv.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

import 'helpers.dart';

Future<void> _pumpWithSnapshot(
  WidgetTester tester,
  String location,
  Map<String, Object?> snapshot,
) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = (await tester.runAsync(() async {
    final store = await memoryStore();
    await store.saveSnapshot(snapshot);
    return store;
  }))!;
  final overrides = (await tester.runAsync(() => testOverrides(store: store)))!;
  final router = createRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('export CSV de l’impact', () {
    test(
      'totaux, indicateurs sociaux, mois et catégories ; virgule décimale',
      () {
        final csv = impactCsv(
          title: 'Impact; test',
          impact: {
            'pickups': 3,
            'items': 5,
            'food_kg': 2.5,
            'co2_kg': 1.2,
            'meals': 6,
          },
          social: {'people_helped': 2},
          socialLabels: {'people_helped': 'Personnes aidées'},
          monthly: [
            {
              'month': '2026-10',
              'pickups': 3,
              'food_kg': 2.5,
              'co2_kg': 1.2,
              'meals': 6,
            },
          ],
          byCategory: [
            {
              'category_name': 'Pain',
              'pickups': 3,
              'food_kg': 2.5,
              'co2_kg': 1.2,
              'meals': 6,
            },
          ],
        );
        final lines = csv.split('\r\n');
        expect(lines.first, '"Impact; test"');
        expect(lines, contains('Nourriture sauvée (kg);2,5'));
        expect(lines, contains('Personnes aidées;2'));
        expect(lines, contains('2026-10;3;2,5;1,2;6'));
        expect(lines, contains('Pain;3;2,5;1,2;6'));
      },
    );
  });

  group('créneaux de retrait', () {
    test('triés ; à défaut, toute la période de l’offre', () {
      final slots = offerSlots({
        'slots': [
          {
            'id': 2,
            'start': '2026-10-05T16:00:00Z',
            'end': '2026-10-05T18:00:00Z',
          },
          {
            'id': 1,
            'start': '2026-10-05T08:00:00Z',
            'end': '2026-10-05T10:00:00Z',
          },
        ],
      });
      expect(slots.map((slot) => slot.id), [1, 2]);

      final single = offerSlots({
        'slots': null,
        'pickup_start': '2026-10-05T08:00:00Z',
        'pickup_end': '2026-10-05T12:00:00Z',
      });
      expect(single, hasLength(1));
      expect(single.single.id, isNull);
    });
  });

  group('favoris', () {
    test('filtre « favoris » : seulement les offres mises en favori', () {
      final offers = [
        {'id': 1, 'title': 'Pain', 'category_id': 1},
        {'id': 2, 'title': 'Riz', 'category_id': 1},
      ];
      final result = filterOffersByOwner(
        available: offers,
        mine: const [],
        origin: null,
        filters: const OfferFilters(favoritesOnly: true),
        favoriteIds: {2},
      );
      expect(result.map((offer) => offer['id']), [2]);
    });

    test('sans compte : gardés sur l’appareil, recherches nommées', () async {
      final store = await memoryStore();
      final container = ProviderContainer(
        overrides: [localStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final favorites = container.read(favoritesProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      await favorites.toggleOffer(7);
      await favorites.saveSearch(
        const SavedSearch(name: 'Pain du soir', text: 'pain', radiusKm: 5),
      );
      await favorites.saveSearch(const SavedSearch(name: 'pain du soir'));
      expect(container.read(favoritesProvider).offerIds, {7});
      // Même nom (casse ignorée) : remplacée, pas en double.
      expect(container.read(favoritesProvider).searches, hasLength(1));

      final saved = Favorites.fromMap(
        await store.readSetting<Object?>('favorites'),
      );
      expect(saved.offerIds, {7});
      expect(saved.searches.single.name, 'pain du soir');

      await favorites.toggleOffer(7);
      expect(container.read(favoritesProvider).offerIds, isEmpty);
    });
  });

  testWidgets('validation des associations : liste, refus avec motif', (
    tester,
  ) async {
    await _pumpWithSnapshot(tester, AppRoutes.adminAssociations, {
      'admin': {
        'pending_associations': [
          {
            'id': 3,
            'name': 'Entraide Quartier',
            'registration_number': 'BF-2026-12',
            'user_name': 'Moussa Kaboré',
            'email': 'entraide@test.local',
            'created_at': '2026-10-01T10:00:00Z',
          },
        ],
      },
    });

    expect(find.text('Entraide Quartier'), findsOneWidget);
    expect(find.textContaining('BF-2026-12'), findsOneWidget);

    await tester.tap(find.text('Refuser'));
    await tester.pumpAndSettle();
    expect(find.text('Refuser « Entraide Quartier » ?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Refuser'));
    await tester.pumpAndSettle();
    expect(find.text('Motif obligatoire'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'Numéro introuvable');
    await tester.tap(find.widgetWithText(FilledButton, 'Refuser'));
    await tester.pumpAndSettle();
    // Hors ligne : décision mise en file, l'association disparaît de la liste.
    expect(find.text('Entraide Quartier'), findsNothing);
  });

  testWidgets('facteurs d’impact : catégories avec et sans facteur', (
    tester,
  ) async {
    await _pumpWithSnapshot(tester, AppRoutes.adminFactors, {
      'categories': [
        {'id': 1, 'name': 'Boulangerie', 'icon': 'bakery_dining'},
        {'id': 2, 'name': 'Poisson'},
      ],
      'admin': {
        'factors': [
          {
            'id': 9,
            'category_id': 1,
            'co2_kg_per_kg': 1.5,
            'meals_per_kg': 2.5,
            'source': 'ADEME',
          },
        ],
      },
    });

    expect(find.textContaining('1,50 kg CO₂/kg'), findsOneWidget);
    expect(find.textContaining('Source : ADEME'), findsOneWidget);
    expect(find.text('Aucun facteur : impact CO₂ non calculé'), findsOneWidget);
  });

  testWidgets('profil : identité, sécurité et notifications', (tester) async {
    await _pumpWithSnapshot(tester, AppRoutes.profile, {
      'profile': {
        'id': 4,
        'name': 'Awa Ouédraogo',
        'first_name': 'Awa',
        'last_name': 'Ouédraogo',
        'email': 'awa@test.local',
        'phone': '+226 70 00 00 00',
        'role': 'beneficiary',
        'actor_label': 'Particulier',
        'preferences': {'push_enabled': false},
      },
    });

    expect(find.text('Awa Ouédraogo'), findsOneWidget);
    expect(find.text('Particulier'), findsOneWidget);
    expect(find.text('Mes informations'), findsOneWidget);
    expect(find.text('Changer mon mot de passe'), findsOneWidget);
    expect(find.text('Mes préférences'), findsOneWidget);
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    // Push désactivé dans le compte ; alertes de recherche actives par défaut.
    expect(switches.map((s) => s.value), [false, true]);
  });

  testWidgets('mes offres : modifier une offre (pré-remplie, hors ligne)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final reserved = {
      ...publishedOffer(id: 8, title: 'Offre déjà réservée'),
      'initial_quantity': 5,
      'quantity_available': 3,
    };
    final store = (await tester.runAsync(() async {
      final store = await memoryStore();
      await store.saveSnapshot({
        'categories': [
          {'id': 1, 'name': 'Fruits et légumes', 'icon': 'eco'},
        ],
        'my_offers': [
          {
            ...publishedOffer(id: 7, title: 'Sac d’oignons', price: 1000),
            'initial_quantity': 5,
            'description': 'Oignons frais',
          },
          reserved,
        ],
      });
      return store;
    }))!;
    final overrides = (await tester.runAsync(
      () => testOverrides(store: store),
    ))!;
    final router = createRouter(initialLocation: AppRoutes.myOffers);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          initialTokenProvider.overrideWithValue('jeton'),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Offre déjà réservée : plus modifiable (le serveur la refuserait),
    // mais ses créneaux le restent.
    expect(find.byTooltip('Modifier l’offre'), findsOneWidget);
    expect(find.byTooltip('Modifier les créneaux de retrait'), findsOneWidget);

    await tester.tap(find.byTooltip('Modifier les créneaux de retrait'));
    await tester.pumpAndSettle();
    expect(find.text('Créneaux de « Offre déjà réservée »'), findsOneWidget);
    await tester.tap(find.text('Enregistrer les créneaux'));
    await tester.pumpAndSettle();
    final queued = (await tester.runAsync(() => Outbox(store.db).all()))!;
    final slots = queued.singleWhere((a) => a.kind == 'offer.slots');
    expect(slots.method, 'PATCH');
    expect(slots.path, '/offers/8/slots');
    expect((slots.body!['slots']! as List), hasLength(1));

    await tester.tap(find.byTooltip('Modifier l’offre'));
    await tester.pumpAndSettle();
    expect(find.text('Modifier l’offre'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Sac d’oignons'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Oignons frais'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '1000'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Sac d’oignons'),
      'Sac d’oignons (prix réduit)',
    );
    await tester.tap(find.text('Enregistrer les modifications'));
    await tester.pumpAndSettle();

    final actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
    final update = actions.singleWhere((a) => a.kind == 'offer.update');
    expect(update.method, 'PUT');
    expect(update.targetId, 7);
    expect(update.body!['title'], 'Sac d’oignons (prix réduit)');
    expect(update.body!['price'], 1000);
    expect(update.body!.containsKey('photo'), isFalse);
  });
}
