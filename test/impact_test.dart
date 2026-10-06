import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

import 'helpers.dart';

/// Espace fine insécable des milliers.
const nbsp = ' ';

/// 12 mois consécutifs, comme les renvoie le serveur ; 2 mois actifs.
List<Map<String, Object>> months() => [
  for (var i = 1; i <= 12; i++)
    {
      'month': '2026-${i.toString().padLeft(2, '0')}',
      'pickups': i == 9 ? 2 : (i == 10 ? 1 : 0),
      'items': 0,
      'food_kg': i == 9 ? 2.5 : (i == 10 ? 1.25 : 0),
      'co2_kg': 0,
      'meals': 0,
    },
];

Future<LocalStore> impactStore(
  WidgetTester tester, {
  String role = 'donor',
  bool withImpact = true,
}) async {
  final store = (await tester.runAsync(memoryStore))!;
  await tester.runAsync(
    () => store.saveSnapshot({
      'profile': {'id': 2, 'name': 'Boulangerie', 'role': role},
      if (withImpact) ...{
        'impact': {
          'pickups': 3,
          'items': 1234,
          'food_kg': 1234.5,
          'co2_kg': 2.25,
          'meals': 12,
        },
        'impact_monthly': months(),
        'impact_by_category': [
          {'category_name': 'Boulangerie', 'food_kg': 3.0},
          {'category_name': 'Fruits et légumes', 'food_kg': 2.0},
        ],
        'impact_social': {
          'offers_shared': 5,
          'pickups_given': 3,
          'people_helped': 4,
          'associations_supported': 1,
          'pickups_received': 0,
          'donors_met': 0,
          'free_received': 0,
        },
        'impact_as_of': '2026-10-02T09:30:00Z',
        'impact_source': 'firestore',
      },
    }),
  );
  return store;
}

Future<void> pumpImpact(
  WidgetTester tester,
  LocalStore store, {
  String location = AppRoutes.impact,
}) async {
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final overrides = await tester.runAsync(() => testOverrides(store: store));
  final router = createRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides!,
        initialTokenProvider.overrideWithValue('jwt-test'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('nombres au format français', () {
    expect(formatNumber(1234.5, decimals: 1), '1${nbsp}234,5');
    expect(formatNumber(12.0, decimals: 1), '12');
    expect(formatNumber(1234567), '1${nbsp}234${nbsp}567');
    expect(formatNumber(0.25, decimals: 1), '0,3');
    expect(formatPrice(1500), '1${nbsp}500 F CFA');
  });

  testWidgets('compteurs formatés, hors ligne, copie de secours signalée', (
    tester,
  ) async {
    await pumpImpact(tester, await impactStore(tester));

    expect(find.text('Mon impact'), findsOneWidget);
    expect(find.text('1${nbsp}234'), findsOneWidget);
    expect(find.text('3 retraits'), findsOneWidget);
    expect(find.text('1${nbsp}234,5 kg'), findsOneWidget);
    expect(find.text('2,3 kg'), findsOneWidget);
    expect(find.textContaining('hors ligne'), findsOneWidget);
    expect(find.textContaining('copie de secours'), findsOneWidget);
  });

  testWidgets('indicateurs sociaux du donateur et graphiques', (tester) async {
    await pumpImpact(tester, await impactStore(tester));

    expect(find.text('Mon impact social'), findsOneWidget);
    expect(find.text('Personnes aidées'), findsOneWidget);
    expect(find.text('Associations soutenues'), findsOneWidget);
    // Donateur sans retrait reçu : pas de cartes bénéficiaire.
    expect(find.text('Donateurs rencontrés'), findsNothing);

    // 12 mois affichés en français, et légende avec kg et part.
    expect(find.text('sept.'), findsOneWidget);
    expect(find.text('déc.'), findsOneWidget);
    expect(find.text('3 kg · 60 %'), findsOneWidget);
    expect(find.text('2 kg · 40 %'), findsOneWidget);
  });

  testWidgets('bénéficiaire : cartes « reçu »', (tester) async {
    await pumpImpact(tester, await impactStore(tester, role: 'beneficiary'));
    expect(find.text('Paniers récupérés'), findsOneWidget);
    expect(find.text('Donateurs rencontrés'), findsOneWidget);
  });

  testWidgets('sans chiffres : message, pas d’erreur', (tester) async {
    await pumpImpact(tester, await impactStore(tester, withImpact: false));
    expect(find.textContaining('Pas encore de chiffres'), findsOneWidget);
  });

  testWidgets('accueil connecté : accès à « Mon impact »', (tester) async {
    await pumpImpact(
      tester,
      await impactStore(tester),
      location: AppRoutes.home,
    );
    await tester.tap(find.text('Mon impact'));
    await tester.pumpAndSettle();
    expect(find.text('Mon impact social'), findsOneWidget);
  });
}
