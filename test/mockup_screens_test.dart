import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/features/impact/presentation/impact_screen.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';

import 'helpers.dart';

void main() {
  test('impact par période : mois en cours, année, ou total', () {
    final total = {'pickups': 9, 'items': 20, 'food_kg': 30.5};
    final monthly = [
      {'month': '2025-12', 'pickups': 4, 'items': 8, 'food_kg': 10},
      {'month': '2026-09', 'pickups': 2, 'items': 5, 'food_kg': 7.5},
      {'month': '2026-10', 'pickups': 1, 'items': 3, 'food_kg': 2},
    ];
    final now = DateTime(2026, 10, 6);

    expect(
      impactForPeriod(ImpactPeriod.all, total: total, monthly: monthly),
      same(total),
    );
    final month = impactForPeriod(
      ImpactPeriod.month,
      total: total,
      monthly: monthly,
      now: now,
    );
    expect(month['pickups'], 1);
    expect(month['food_kg'], 2);
    final year = impactForPeriod(
      ImpactPeriod.year,
      total: total,
      monthly: monthly,
      now: now,
    );
    expect(year['items'], 8);
    expect(year['food_kg'], 9.5);
    expect(year['co2_kg'], 0);
  });

  test('notifications rangées par onglet', () {
    NotificationKind kind(String type) => NotificationKind.of({'type': type});

    for (final type in [
      'reservation_created',
      'reservation_confirmed',
      'reservation_cancelled',
      'pickup_reminder',
      'pickup_done',
      'confirm_reminder',
      'slot_changed',
    ]) {
      expect(kind(type), NotificationKind.reservations, reason: type);
    }
    expect(kind('expiry_soon'), NotificationKind.tips);
    expect(kind('search_match'), NotificationKind.tips);
    expect(kind('account_status'), NotificationKind.infos);
    expect(kind('association_review'), NotificationKind.infos);
    expect(kind('offer_moderated'), NotificationKind.infos);
  });

  test('notification d’un message entre utilisateurs : ouvre l’échange', () {
    expect(
      notificationLink({
        'type': 'direct_message',
        'data': {'peer_id': 5, 'offer_id': 9},
      }),
      AppRoutes.directConversation(5),
    );
  });

  testWidgets('filtres : rien avant « Appliquer », puis liste filtrée', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(() async {
      final store = await memoryStore();
      await store.saveSnapshot({
        'categories': [
          {'id': 1, 'name': 'Fruits et légumes', 'icon': 'eco'},
        ],
        'offers': [
          publishedOffer(id: 1, title: 'Mangues payantes', price: 500),
          publishedOffer(id: 2, title: 'Pain offert'),
        ],
      });
      return store;
    }))!;
    final overrides = (await tester.runAsync(
      () => testOverrides(store: store),
    ))!;
    final router = createRouter(initialLocation: AppRoutes.search);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mangues payantes'), findsOneWidget);

    await tester.tap(find.byTooltip('Filtres'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gratuit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appliquer les filtres'));
    await tester.pumpAndSettle();

    expect(find.text('Offres disponibles'), findsOneWidget);
    expect(find.text('Mangues payantes'), findsNothing);
    expect(find.text('Pain offert'), findsOneWidget);
    // Critère actif affiché, retirable d'un geste.
    await tester.tap(find.byTooltip('Retirer'));
    await tester.pumpAndSettle();
    expect(find.text('Mangues payantes'), findsOneWidget);
  });
}
