import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';

import 'helpers.dart';

const actors = [
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
];

const users = [
  {
    'id': 3,
    'name': 'Awa Traoré',
    'email': 'awa@test.local',
    'role': 'beneficiary',
    'actor_label': 'Particulier',
    'status': 'active',
  },
  {
    'id': 4,
    'name': 'Jean Dupont',
    'email': 'jean@test.local',
    'role': 'donor',
    'actor_label': 'Commerçant',
    'status': 'suspended',
    'status_reason': 'Abus',
  },
];

/// Texte propre à chaque écran implémenté (les autres affichent leur titre
/// dans la barre du haut).
const implementedScreens = {
  AppRoutes.splash: 'Commencer',
  AppRoutes.login: 'Se connecter',
  AppRoutes.register: 'Choisissez votre rôle',
  AppRoutes.home: 'Publier une offre',
};

Future<List<Override>> screenOverrides({
  LocalStore? store,
  LocationGateway? location,
}) async => [
  ...await testOverrides(store: store, location: location),
  authGatewayProvider.overrideWithValue(FakeAuthGateway()),
  signupActorsProvider.overrideWith((ref) async => actors),
  adminUsersProvider.overrideWith((ref, filters) async => users),
];

Future<void> pumpRoute(
  WidgetTester tester,
  String location, {
  LocalStore? store,
  bool Function()? isLoggedIn,
}) async {
  final overrides = await tester.runAsync(() => screenOverrides(store: store));
  final router = createRouter(
    initialLocation: location,
    isLoggedIn: isLoggedIn,
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides!,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("L'application démarre sur l'écran d'accueil", (tester) async {
    final overrides = await tester.runAsync(testOverrides);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides!, child: const RepasPartageApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Commencer'), findsOneWidget);
    expect(find.text('Se connecter'), findsOneWidget);
  });

  testWidgets('Hors ligne, le bandeau le signale', (tester) async {
    final overrides = await tester.runAsync(testOverrides);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides!, child: const RepasPartageApp()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Hors ligne'), findsOneWidget);
  });

  for (final entry in allRouteEntries) {
    testWidgets('La route ${entry.location} affiche « ${entry.title} »', (
      tester,
    ) async {
      await pumpRoute(tester, entry.location);

      final expected = implementedScreens[entry.location];
      expect(
        expected == null
            ? find.widgetWithText(AppBar, entry.title)
            : find.text(expected),
        findsWidgets,
      );
    });
  }

  group('inscription', () {
    testWidgets('choix du rôle puis formulaire complet', (tester) async {
      await pumpRoute(tester, AppRoutes.register);

      expect(find.text('Particulier'), findsOneWidget);
      expect(find.text('Commerçant'), findsOneWidget);

      await tester.tap(find.text('Commerçant'));
      await tester.pumpAndSettle();

      expect(find.text('Profil : Commerçant'), findsOneWidget);
      for (final label in [
        'Nom',
        'Prénom',
        'Sexe',
        'Âge',
        'Adresse e-mail',
        'Téléphone',
        'Mot de passe',
        'Confirmer le mot de passe',
      ]) {
        expect(find.text('$label *'), findsOneWidget, reason: label);
      }
    });

    testWidgets('champs obligatoires signalés', (tester) async {
      await pumpRoute(tester, AppRoutes.register);
      await tester.tap(find.text('Particulier'));
      await tester.pumpAndSettle();

      final submit = find.text('Créer mon compte');
      await tester.dragUntilVisible(
        submit,
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.text('Nom obligatoire'), findsOneWidget);
      expect(find.text('Sexe obligatoire'), findsOneWidget);
      expect(find.text('Âge obligatoire'), findsOneWidget);
      expect(find.text('Adresse e-mail obligatoire'), findsOneWidget);
      expect(find.text('Téléphone obligatoire'), findsOneWidget);
      expect(find.text('Mot de passe obligatoire'), findsOneWidget);
      expect(find.text('Confirmation obligatoire'), findsOneWidget);
    });
  });

  testWidgets('activation : e-mail pré-rempli, code à 6 chiffres exigé', (
    tester,
  ) async {
    await pumpRoute(tester, AppRoutes.verifyEmailFor('awa@test.local'));

    expect(find.text('awa@test.local'), findsOneWidget);
    expect(find.textContaining('Renvoyer le code ('), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).last, '123');
    await tester.tap(find.text('Activer mon compte'));
    await tester.pumpAndSettle();
    expect(find.text('Le code contient 6 chiffres'), findsOneWidget);

    // Laisse le compte à rebours se terminer (pas de minuterie en suspens).
    await tester.pump(const Duration(seconds: 61));
    expect(find.text('Renvoyer le code'), findsOneWidget);
  });

  testWidgets('modération : comptes listés, désactivation avec motif', (
    tester,
  ) async {
    await pumpRoute(tester, AppRoutes.adminAccounts);

    expect(find.text('Awa Traoré'), findsOneWidget);
    expect(find.text('Actif'), findsOneWidget);
    expect(find.text('Désactivé'), findsOneWidget);
    expect(find.text('Motif : Abus'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('Désactiver le compte ?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Désactiver'));
    await tester.pumpAndSettle();
    expect(find.text('Motif obligatoire'), findsOneWidget);
  });

  group('sans compte', () {
    Future<LocalStore> storeWithOffers(WidgetTester tester) async {
      final store = (await tester.runAsync(memoryStore))!;
      await tester.runAsync(
        () => store.saveSnapshot({
          'categories': [
            {'id': 1, 'name': 'Fruits et légumes', 'icon': 'eco'},
          ],
          'offers': [
            publishedOffer(id: 1, title: 'Panier de mangues', price: 250),
            publishedOffer(id: 2, title: 'Pains du jour', lat: 12.38),
            // ~110 km : hors du rayon par défaut.
            publishedOffer(id: 3, title: 'Offre lointaine', lat: 13.37),
          ],
        }),
      );
      return store;
    }

    testWidgets(
      '« Commencer » demande la position puis liste les offres proches',
      (tester) async {
        final store = await storeWithOffers(tester);
        await pumpRoute(tester, AppRoutes.splash, store: store);

        expect(find.text('S’inscrire'), findsOneWidget);
        await tester.tap(find.text('Commencer'));
        await tester.pumpAndSettle();

        expect(find.textContaining('Ma position'), findsOneWidget);
        expect(find.text('Panier de mangues'), findsOneWidget);
        await tester.dragUntilVisible(
          find.text('Pains du jour'),
          find.byType(CustomScrollView),
          const Offset(0, -200),
        );
        expect(find.text('Offre lointaine'), findsNothing);
        expect(find.text('250 F CFA'), findsOneWidget);
      },
    );

    testWidgets('la recherche filtre les offres par texte', (tester) async {
      final store = await storeWithOffers(tester);
      await pumpRoute(tester, AppRoutes.search, store: store);

      await tester.enterText(find.byType(TextField).first, 'mangue');
      await tester.pumpAndSettle();

      expect(find.text('Panier de mangues'), findsOneWidget);
      expect(find.text('Pains du jour'), findsNothing);
    });

    testWidgets('position refusée : message et choix d’un autre point', (
      tester,
    ) async {
      final overrides = await tester.runAsync(
        () => screenOverrides(
          location: FakeLocation(
            failure: const LocationFailure('Position non autorisée'),
          ),
        ),
      );
      final router = createRouter(initialLocation: AppRoutes.home);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides!,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Position non autorisée'), findsOneWidget);
      expect(find.text('Changer'), findsOneWidget);
      expect(find.byTooltip('Revenir à ma position'), findsOneWidget);
    });

    testWidgets(
      'offre payante : détail puis réservation invité avec référence',
      (tester) async {
        final store = await storeWithOffers(tester);
        await pumpRoute(tester, AppRoutes.offer('1'), store: store);

        expect(find.text('Panier de mangues'), findsOneWidget);
        expect(find.textContaining('Orange Money'), findsOneWidget);

        await tester.tap(find.text('Réserver'));
        await tester.pumpAndSettle();

        expect(find.text('Référence de la transaction'), findsOneWidget);
        expect(find.text('Téléphone *'), findsOneWidget);
        expect(find.text('À payer : 250 F CFA'), findsOneWidget);

        await tester.tap(find.byTooltip('Plus'));
        await tester.pumpAndSettle();
        expect(find.text('À payer : 500 F CFA'), findsOneWidget);

        final submit = find.text('Confirmer la réservation');
        await tester.dragUntilVisible(
          submit,
          find.byType(ListView),
          const Offset(0, -300),
        );
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(
          find.text('Référence obligatoire (4 caractères minimum)'),
          findsOneWidget,
        );
        expect(find.text('Numéro invalide'), findsOneWidget);
      },
    );

    testWidgets('publier sans compte : identité demandée', (tester) async {
      final store = await storeWithOffers(tester);
      await pumpRoute(tester, AppRoutes.createOffer, store: store);

      expect(find.text('Fruits et légumes'), findsOneWidget);
      await tester.dragUntilVisible(
        find.textContaining('Publiez sans compte'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      expect(find.textContaining('Publiez sans compte'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('Prix réduit'),
        find.byType(ListView),
        const Offset(0, 300),
      );
      await tester.tap(find.text('Prix réduit'));
      await tester.pumpAndSettle();
      expect(find.text('Comment payer ? *'), findsOneWidget);
    });

    testWidgets('publier : formulaire en 4 colonnes, sans défilement', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 906);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await storeWithOffers(tester);
      await pumpRoute(tester, AppRoutes.createOffer, store: store);

      // Quantité, Unité, Poids et Date limite sur la même rangée.
      final top = tester.getTopLeft(find.text('Quantité *')).dy;
      expect(
        tester.getTopLeft(find.text('Date limite de consommation *')).dy,
        top,
      );
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scroll.position.maxScrollExtent, 0);
    });

    testWidgets('écran réservé aux comptes : redirection vers la connexion', (
      tester,
    ) async {
      await pumpRoute(tester, AppRoutes.profile, isLoggedIn: () => false);

      expect(find.text('Connexion'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Profil'), findsNothing);
    });
  });
}
