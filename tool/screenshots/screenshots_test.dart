// Génère les captures d'écran du README (docs/screenshots/*.png) :
//
//   flutter test tool/screenshots --update-goldens
//
// Écrans réels de l'application, remplis avec des données de démonstration
// (aucun serveur requis). Hors du dossier test/ : non lancé par la CI, les
// rendus pouvant varier légèrement d'une machine à l'autre.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/offline/offline_banner.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';
import 'package:repo_partage_plus/features/recommendations/data/ai_refiner.dart';

import '../../test/helpers.dart';

// ---------- Polices (sinon le texte s'affiche en carrés) ----------

Future<void> _loadFonts() async {
  // flutter_tester est dans <flutter>/bin/cache/artifacts/engine/<plateforme>/
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
  final fonts = '${artifacts.path}/material_fonts';
  Future<ByteData> read(String name) async =>
      ByteData.sublistView(await File('$fonts/$name').readAsBytes());

  await (FontLoader('Roboto')
        ..addFont(read('roboto-regular.ttf'))
        ..addFont(read('roboto-medium.ttf'))
        ..addFont(read('roboto-bold.ttf')))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(read('materialicons-regular.otf'))).load();
}

// ---------- Données de démonstration (Ouagadougou) ----------

final _now = DateTime.now();
String _iso(Duration shift) => _now.add(shift).toUtc().toIso8601String();
String _day(int days) =>
    _now.add(Duration(days: days)).toIso8601String().substring(0, 10);

const _categories = [
  {'id': 1, 'name': 'Fruits et légumes', 'icon': 'eco'},
  {'id': 2, 'name': 'Boulangerie', 'icon': 'bakery_dining'},
  {'id': 3, 'name': 'Plats cuisinés', 'icon': 'restaurant'},
  {'id': 4, 'name': 'Produits laitiers', 'icon': 'egg'},
  {'id': 5, 'name': 'Épicerie', 'icon': 'shopping_basket'},
];

Map<String, dynamic> _offer(
  int id,
  String title,
  int category,
  String donor,
  String publisher, {
  double km = 0.5,
  num price = 0,
  int expiry = 1,
  String unit = 'portion',
  int quantity = 5,
}) {
  final categoryName = _categories[category - 1]['name'];
  return {
    ...publishedOffer(
      id: id,
      title: title,
      lat: 12.3714 + km / 111,
      lng: -1.5197 + km / 222,
      price: price,
      categoryId: category,
    ),
    'category_name': categoryName,
    'category_icon': _categories[category - 1]['icon'],
    'donor_name': donor,
    'publisher_type': publisher,
    'unit': unit,
    'quantity_available': quantity,
    'weight_kg': 4,
    'expiry_date': _day(expiry),
    'address': 'Avenue Kwame Nkrumah, Ouagadougou',
    'description':
        'Produits frais du jour, en parfait état. Apportez un sac pour le '
        'retrait.',
    'pickup_start': _iso(const Duration(hours: 1)),
    'pickup_end': _iso(const Duration(hours: 5)),
  };
}

final _offers = [
  _offer(
    1,
    'Panier de légumes frais',
    1,
    'Marché du Centre',
    'commercant',
    km: 0.4,
    unit: 'panier',
    quantity: 3,
  ),
  _offer(
    2,
    'Pains et viennoiseries',
    2,
    'Boulangerie La Belle Vie',
    'commercant',
    km: 0.6,
    price: 250,
    unit: 'pièce',
    quantity: 20,
  ),
  _offer(
    3,
    'Riz sauce arachide',
    3,
    'Restaurant Le Partage',
    'restaurateur',
    km: 1.2,
    expiry: 0,
    quantity: 12,
  ),
  _offer(
    4,
    'Yaourts nature',
    4,
    'Supérette Bon Prix',
    'commercant',
    km: 0.7,
    price: 150,
    expiry: 2,
    unit: 'pot',
    quantity: 12,
  ),
  _offer(
    5,
    'Panier de mangues',
    1,
    'Awa Traoré',
    'particulier',
    km: 2.5,
    expiry: 3,
    unit: 'panier',
    quantity: 4,
  ),
  _offer(
    6,
    'Sacs de riz 5 kg',
    5,
    'Épicerie du Quartier',
    'commercant',
    km: 3.1,
    price: 2000,
    expiry: 30,
    unit: 'sac',
    quantity: 4,
  ),
];

Future<void> _seed(LocalStore store) async {
  await store.saveSnapshot({'categories': _categories, 'offers': _offers});
  await store.saveSetting('origin', {
    'lat': 12.3714,
    'lng': -1.5197,
    'label': 'Ma position',
    'is_current': true,
  });
  await store.saveGuestItem('offers', {
    ..._offer(20, 'Surplus de tomates', 1, 'Moussa Kaboré', 'invite'),
    'status': 'pending',
    'guest_token': 'demo',
  });
  await store.saveGuestItem('offers', {
    ..._offer(
      21,
      'Beignets du matin',
      2,
      'Moussa Kaboré',
      'invite',
      price: 100,
    ),
    'guest_token': 'demo',
  });
  await store.saveGuestItem('reservations', {
    'id': 30,
    'offer_id': 2,
    'offer_title': 'Pains et viennoiseries',
    'status': 'pending',
    'quantity': 2,
    'amount': 500,
    'payment_reference': 'OM240930.1542.B77',
    'pickup_code': '482915',
    'donor_name': 'Boulangerie La Belle Vie',
    'donor_phone': '+226 70 12 34 56',
    'address': 'Avenue Kwame Nkrumah, Ouagadougou',
    'latitude': 12.377,
    'longitude': -1.517,
    'pickup_start': _iso(const Duration(hours: 1)),
    'pickup_end': _iso(const Duration(hours: 5)),
    'created_at': _iso(Duration.zero),
    'guest_token': 'demo',
  });
  await store.saveSnapshot({
    'admin': {
      'actors': [
        for (final (i, a) in const [
          (
            'particulier',
            'Particulier',
            'Je souhaite récupérer des produits',
            'person',
            'beneficiary',
            1,
            42,
          ),
          (
            'commercant',
            'Commerçant',
            'Je souhaite publier des produits',
            'storefront',
            'donor',
            1,
            18,
          ),
          (
            'restaurateur',
            'Restaurateur',
            'Je souhaite publier des produits',
            'restaurant',
            'donor',
            1,
            7,
          ),
          (
            'administrateur',
            'Administrateur',
            'Gère la plateforme',
            'admin_panel_settings',
            'admin',
            0,
            2,
          ),
        ].indexed)
          {
            'id': i + 1,
            'code': a.$1,
            'label': a.$2,
            'description': a.$3,
            'icon': a.$4,
            'permission_role': a.$5,
            'self_signup': a.$6,
            'active': 1,
            'sort_order': i,
            'users_count': a.$7,
          },
      ],
    },
  });
}

const _signupActors = [
  {
    'id': 1,
    'code': 'particulier',
    'label': 'Particulier',
    'description': 'Je souhaite récupérer des produits',
    'icon': 'person',
    'permission_role': 'beneficiary',
  },
  {
    'id': 2,
    'code': 'commercant',
    'label': 'Commerçant',
    'description': 'Je souhaite publier des produits',
    'icon': 'storefront',
    'permission_role': 'donor',
  },
  {
    'id': 3,
    'code': 'restaurateur',
    'label': 'Restaurateur',
    'description': 'Je souhaite publier des produits',
    'icon': 'restaurant',
    'permission_role': 'donor',
  },
];

final _users = [
  for (final (i, u) in const [
    ('Jean Dupont', 'jean.dupont@mail.com', 'Particulier', 'active', null),
    ('Awa Traoré', 'awa@commerce.bf', 'Commerçant', 'active', null),
    (
      'Restaurant Le Soleil',
      'contact@lesoleil.bf',
      'Restaurateur',
      'active',
      null,
    ),
    (
      'Issa Kaboré',
      'issa@mail.com',
      'Particulier',
      'suspended',
      'Réservations non retirées à répétition',
    ),
    ('Fatou Ouédraogo', 'fatou@mail.com', 'Particulier', 'pending', null),
  ].indexed)
    {
      'id': i + 10,
      'name': u.$1,
      'email': u.$2,
      'role': u.$3 == 'Particulier' ? 'beneficiary' : 'donor',
      'actor_label': u.$3,
      'status': u.$4,
      'status_reason': u.$5,
    },
];

/// IA factice : affine le classement avec des justifications réalistes.
class _DemoAi implements AiRefiner {
  @override
  Future<AiRefinement> refine(Map<String, Object?> payload) async =>
      const AiRefinement(
        ranking: [
          (id: 3, reason: 'Plat prêt à emporter ce soir, expire aujourd’hui'),
          (id: 1, reason: 'Légumes frais tout près, comme demandé'),
          (id: 5, reason: 'Vous réservez souvent des fruits'),
        ],
        model: 'démo',
      );
}

// ---------- Capture ----------

Future<void> _shot(
  WidgetTester tester,
  String name,
  String location, {
  bool online = true,
  Future<void> Function()? before,
}) async {
  tester.view
    ..physicalSize = const Size(390 * 2, 844 * 2)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final store = (await tester.runAsync(memoryStore))!;
  await tester.runAsync(() => _seed(store));
  final overrides = (await tester.runAsync(
    () => testOverrides(store: store, online: online),
  ))!;
  final router = createRouter(initialLocation: location);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ...overrides,
        authGatewayProvider.overrideWithValue(FakeAuthGateway()),
        signupActorsProvider.overrideWith((ref) async => _signupActors),
        adminUsersProvider.overrideWithValue(_users),
        aiRefinerProvider.overrideWithValue(_DemoAi()),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        routerConfig: router,
        builder: (context, child) => OfflineBanner(child: child!),
      ),
    ),
  );
  await _settle(tester);
  if (before != null) {
    await before();
    await _settle(tester);
  }

  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../../docs/screenshots/$name.png'),
  );
}

/// Laisse les chargements se terminer, sans bloquer sur une animation continue.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    // Cache de tuiles de la carte : dossier temporaire au lieu du plugin natif.
    final cache = Directory.systemTemp.createTempSync('partage_tiles').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => cache,
        );
  });

  testWidgets('01 accueil', (t) => _shot(t, '01_accueil', AppRoutes.splash));
  testWidgets('02 connexion', (t) => _shot(t, '02_connexion', AppRoutes.login));
  testWidgets(
    '03 inscription : rôle',
    (t) => _shot(t, '03_inscription_role', AppRoutes.register),
  );
  testWidgets(
    '04 inscription : formulaire',
    (t) => _shot(
      t,
      '04_inscription_formulaire',
      AppRoutes.register,
      before: () => t.tap(find.text('Commerçant')),
    ),
  );
  testWidgets('05 activation', (t) async {
    await _shot(
      t,
      '05_activation',
      AppRoutes.verifyEmailFor('awa.traore@mail.com'),
    );
    // Laisse le compte à rebours du renvoi de code se terminer.
    await t.pump(const Duration(seconds: 61));
  });
  testWidgets(
    '06 offres à proximité',
    (t) => _shot(t, '06_offres_proximite', AppRoutes.home),
  );
  testWidgets(
    '07 recherche',
    (t) => _shot(
      t,
      '07_recherche',
      AppRoutes.search,
      before: () => t.enterText(find.byType(TextField).first, 'pa'),
    ),
  );
  testWidgets('08 carte', (t) => _shot(t, '08_carte', AppRoutes.nearbyMap));
  testWidgets(
    '09 fiche offre',
    (t) => _shot(t, '09_fiche_offre', AppRoutes.offer('2')),
  );
  testWidgets(
    '10 réserver',
    (t) => _shot(t, '10_reserver', AppRoutes.reserve(2)),
  );
  testWidgets(
    '11 confirmation',
    (t) => _shot(t, '11_confirmation', AppRoutes.confirmation('30')),
  );
  testWidgets(
    '12 publier',
    (t) => _shot(t, '12_publier', AppRoutes.createOffer),
  );
  testWidgets(
    '13 mes offres',
    (t) => _shot(t, '13_mes_offres', AppRoutes.myOffers),
  );
  testWidgets(
    '14 mes réservations',
    (t) => _shot(t, '14_mes_reservations', AppRoutes.myReservations),
  );
  testWidgets(
    '15 recommandations IA',
    (t) => _shot(
      t,
      '15_recommandations',
      AppRoutes.recommendations,
      before: () => t.tap(find.text('Recommander')),
    ),
  );
  testWidgets(
    '16 recommandations hors ligne',
    (t) => _shot(
      t,
      '16_recommandations_hors_ligne',
      AppRoutes.recommendations,
      online: false,
    ),
  );
  testWidgets(
    '17 admin : comptes',
    (t) => _shot(t, '17_admin_comptes', AppRoutes.adminAccounts),
  );
  testWidgets(
    '18 admin : acteurs',
    (t) => _shot(t, '18_admin_acteurs', AppRoutes.adminActors),
  );
}
