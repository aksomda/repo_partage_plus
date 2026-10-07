import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

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
final implementedScreens = {
  AppRoutes.splash: 'Commencer',
  AppRoutes.login: 'Se connecter',
  AppRoutes.register: 'Choisissez votre rôle',
  AppRoutes.home: 'Voir les offres autour de vous',
  AppRoutes.pickup('1'): 'Valider le retrait',
};

Future<List<Override>> screenOverrides({
  LocalStore? store,
  LocationGateway? location,
}) async => [
  ...await testOverrides(store: store, location: location),
  authGatewayProvider.overrideWithValue(FakeAuthGateway()),
  signupActorsProvider.overrideWith((ref) async => actors),
  adminUsersProvider.overrideWithValue(users),
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

/// Tous les écrans déclarés (titre, chemin) : chacun doit s'ouvrir.
final allRoutes = <(String, String)>[
  ('Démarrage', AppRoutes.splash),
  ('Accueil', AppRoutes.home),
  ('Offres disponibles', AppRoutes.search),
  ('Filtres', AppRoutes.filters),
  ('Mode hors ligne', AppRoutes.offline),
  ('Point de départ', AppRoutes.pickLocation),
  ('Connexion', AppRoutes.login),
  ('Inscription', AppRoutes.register),
  ('Activation du compte', AppRoutes.verifyEmail),
  ('Mot de passe oublié', AppRoutes.forgotPassword),
  ('Profil', AppRoutes.profile),
  ('Offres à proximité', AppRoutes.nearbyMap),
  ('Publier une offre', AppRoutes.createOffer),
  ('Mes offres', AppRoutes.myOffers),
  ("Détail de l'offre", AppRoutes.offer('1')),
  ('Recommandations', AppRoutes.recommendations),
  ('Réserver', AppRoutes.reserve(1)),
  ('Mes réservations', AppRoutes.myReservations),
  ('Confirmation de réservation', AppRoutes.confirmation('1')),
  ('Retrait', AppRoutes.pickup('1')),
  ('Notifications', AppRoutes.notifications),
  ('Messages', AppRoutes.messages),
  ('Équipe Partage+', AppRoutes.teamMessages),
  ('Mon impact', AppRoutes.impact),
  ('Facteurs d’impact', AppRoutes.adminFactors),
  ('Tableau de bord', AppRoutes.adminDashboard),
  ('Administration', AppRoutes.adminManage),
  ('Réservations de la plateforme', AppRoutes.adminReservations),
  ('Impact de la plateforme', AppRoutes.adminImpact),
  ('Modération des offres', AppRoutes.adminOffers),
  ('Gestion des utilisateurs', AppRoutes.adminAccounts),
  ('Catégories', AppRoutes.adminCategories),
  ('Acteurs', AppRoutes.adminActors),
  ('Paramètres', AppRoutes.adminSettings),
];

void main() {
  testWidgets("L'application démarre sur l'écran d'accueil", (tester) async {
    final overrides = await tester.runAsync(testOverrides);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides!, child: const RepasPartageApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Commencer'), findsOneWidget);
    expect(find.text('Déjà un compte ? Se connecter'), findsOneWidget);
    expect(find.text('Vous n’avez pas de compte ?'), findsOneWidget);
    expect(find.text('S’inscrire'), findsOneWidget);
  });

  testWidgets('Hors ligne, le bandeau le signale', (tester) async {
    final overrides = await tester.runAsync(testOverrides);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides!, child: const RepasPartageApp()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Hors ligne'), findsOneWidget);
  });

  for (final (title, location) in allRoutes) {
    testWidgets('La route $location affiche « $title »', (tester) async {
      await pumpRoute(tester, location);

      final expected = implementedScreens[location];
      expect(
        expected == null
            ? find.widgetWithText(AppBar, title)
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

      final submit = find.text('Suivant');
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
      // Saisie incomplète : pas d'étape de vérification.
      expect(find.text('Vérifiez vos informations'), findsNothing);
    });

    testWidgets('vérification non modifiable, « Précédent » pour corriger', (
      tester,
    ) async {
      await pumpRoute(tester, AppRoutes.register);
      await tester.tap(find.text('Particulier'));
      await tester.pumpAndSettle();

      Future<void> fill(String hint, String text) =>
          tester.enterText(find.widgetWithText(TextFormField, hint), text);
      await fill('Ouédraogo', 'Traoré');
      await fill('Awa', 'Awa');
      await tester.tap(find.text('Femme'));
      await fill('25', '28');
      await fill('exemple@mail.com', 'Awa@Test.local');
      await fill('73290554', '73 29 05 54');
      await fill('8 caractères, lettres et chiffres', 'motdepasse1');
      await fill('Saisissez-le à nouveau', 'motdepasse1');
      await tester.ensureVisible(find.text('Suivant'));
      await tester.tap(find.text('Suivant'));
      await tester.pumpAndSettle();

      expect(find.text('Vérifiez vos informations'), findsOneWidget);
      expect(find.text('Traoré'), findsOneWidget);
      expect(find.text('Femme'), findsOneWidget);
      expect(find.text('28 ans'), findsOneWidget);
      expect(find.text('awa@test.local'), findsOneWidget);
      expect(find.textContaining('+226 73290554'), findsOneWidget);
      expect(find.text('•••••••••••'), findsOneWidget);
      // Aucun champ modifiable à cette étape.
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Valider'), findsOneWidget);

      await tester.tap(find.text('Précédent'));
      await tester.pumpAndSettle();
      expect(find.text('Vos informations'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Traoré'), findsOneWidget);
    });

    testWidgets('nom composé accepté ; mots de passe différents à ressaisir', (
      tester,
    ) async {
      await pumpRoute(tester, AppRoutes.register);
      await tester.tap(find.text('Particulier'));
      await tester.pumpAndSettle();

      Future<void> fill(String hint, String text) =>
          tester.enterText(find.widgetWithText(TextFormField, hint), text);
      await fill('Ouédraogo', 'K.SOMDA/HETIE');
      await fill('8 caractères, lettres et chiffres', 'motdepasse1');
      await fill('Saisissez-le à nouveau', 'motdepasse2');
      await tester.ensureVisible(find.text('Suivant'));
      await tester.tap(find.text('Suivant'));
      await tester.pumpAndSettle();

      expect(find.text('Nom invalide'), findsNothing);
      expect(
        find.text('Les mots de passe ne correspondent pas'),
        findsOneWidget,
      );

      // Corriger le premier champ efface l'erreur de la confirmation.
      await fill('8 caractères, lettres et chiffres', 'motdepasse2');
      await tester.pumpAndSettle();
      expect(find.text('Les mots de passe ne correspondent pas'), findsNothing);
      expect(find.text('Ressaisir le mot de passe'), findsNothing);

      // De nouveau différents : « Ressaisir » vide les deux champs.
      await fill('8 caractères, lettres et chiffres', 'autre1234');
      await tester.tap(find.text('Suivant'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Ressaisir le mot de passe'));
      await tester.tap(find.text('Ressaisir le mot de passe'));
      await tester.pumpAndSettle();
      expect(find.text('Les mots de passe ne correspondent pas'), findsNothing);
      expect(find.widgetWithText(TextFormField, 'autre1234'), findsNothing);
      expect(find.widgetWithText(TextFormField, 'motdepasse2'), findsNothing);
    });
  });

  testWidgets('menu sans compte : écrans utiles, descriptions, sans chemins', (
    tester,
  ) async {
    await pumpRoute(tester, AppRoutes.adminSettings);
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();

    final drawer = find.byType(Drawer);
    for (final item in guestMenu.expand((section) => section.items)) {
      expect(
        find.descendant(of: drawer, matching: find.text(item.title)),
        findsOneWidget,
        reason: item.title,
      );
      // Description affichée au survol (appui long sur téléphone).
      expect(find.byTooltip(item.description), findsWidgets);
    }
    // Ni écrans d'administration ni chemins techniques.
    expect(
      find.descendant(of: drawer, matching: find.text('Tableau de bord')),
      findsNothing,
    );
    expect(find.text('/home'), findsNothing);
    // Plus d'outil de développement dans le menu.
    expect(find.text('Développement : tous les écrans'), findsNothing);
  });

  testWidgets('mot de passe : bouton Effacer dès que le champ est rempli', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasswordField(controller: controller, onChanged: changes.add),
        ),
      ),
    );

    expect(find.byTooltip('Effacer'), findsNothing);
    await tester.enterText(find.byType(TextFormField), 'secret123');
    await tester.pump();
    await tester.tap(find.byTooltip('Effacer'));
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(changes.last, isEmpty);
    expect(find.byTooltip('Effacer'), findsNothing);
  });

  test('menu selon le rôle et l’acteur', () {
    expect(menuFor(loggedIn: false), guestMenu);
    expect(menuFor(loggedIn: true, role: 'admin'), adminMenu);
    expect(
      menuFor(loggedIn: true, role: 'beneficiary', actorCode: 'particulier'),
      particulierMenu,
    );
    expect(
      menuFor(loggedIn: true, role: 'donor', actorCode: 'commercant'),
      commercantMenu,
    );
    expect(
      menuFor(loggedIn: true, role: 'donor', actorCode: 'restaurateur'),
      restaurateurMenu,
    );
    expect(
      menuFor(loggedIn: true, role: 'association', actorCode: 'association'),
      associationMenu,
    );
    // Acteur créé par l'administrateur : menu de ses droits.
    expect(
      menuFor(loggedIn: true, role: 'donor', actorCode: 'traiteur'),
      commercantMenu,
    );
    expect(menuFor(loggedIn: true, role: 'beneficiary'), particulierMenu);

    // Couleur du tiroir : mêmes règles que le menu.
    expect(menuColorFor(loggedIn: false), MenuColors.guest);
    expect(menuColorFor(loggedIn: true, role: 'admin'), MenuColors.admin);
    expect(
      menuColorFor(loggedIn: true, role: 'donor', actorCode: 'restaurateur'),
      MenuColors.restaurateur,
    );
    expect(
      menuColorFor(loggedIn: true, role: 'donor', actorCode: 'traiteur'),
      MenuColors.commercant,
    );
    expect(
      menuColorFor(loggedIn: true, role: 'association'),
      MenuColors.association,
    );
    expect(menuColorFor(loggedIn: true), MenuColors.particulier);

    // Aucun écran d'administration ni de connexion dans les menus des acteurs.
    for (final menu in [
      particulierMenu,
      commercantMenu,
      restaurateurMenu,
      associationMenu,
    ]) {
      final locations = menu.expand((s) => s.items).map((i) => i.location);
      expect(locations, isNot(contains(AppRoutes.login)));
      expect(locations.where(AppRoutes.requiresAdmin), isEmpty);
      expect(locations, contains(AppRoutes.profile));
    }
  });

  testWidgets('association : menu accessible depuis les écrans principaux', (
    tester,
  ) async {
    final store = await tester.runAsync(memoryStore);
    await tester.runAsync(
      () => store!.saveSnapshot({
        'profile': {
          'id': 7,
          'name': 'Banque alimentaire',
          'role': 'association',
          'actor_code': 'association',
        },
      }),
    );
    final overrides = await tester.runAsync(
      () => screenOverrides(store: store),
    );

    for (final location in [
      AppRoutes.home,
      AppRoutes.nearbyMap,
      AppRoutes.myReservations,
      AppRoutes.impact,
    ]) {
      final router = createRouter(initialLocation: location);
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(location),
          overrides: [
            ...overrides!,
            initialTokenProvider.overrideWithValue('jeton'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DrawerButton));
      await tester.pumpAndSettle();
      final drawer = find.byType(Drawer);
      expect(
        find.descendant(of: drawer, matching: find.text('Mes collectes')),
        findsOneWidget,
        reason: location,
      );
      router.dispose();
    }
  });

  testWidgets('écran d’administration refusé à un compte non administrateur', (
    tester,
  ) async {
    final overrides = await tester.runAsync(screenOverrides);
    final router = createRouter(
      initialLocation: AppRoutes.adminSettings,
      isLoggedIn: () => true,
      isAdmin: () => false,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides!,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, AppRoutes.home);
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

  testWidgets(
    'gestion des utilisateurs : copie locale, compteurs, ajout hors ligne',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final store = (await tester.runAsync(() async {
        final store = await memoryStore();
        await store.saveSnapshot({
          'admin': {
            'users': users,
            'actors': [
              {...actors.first, 'active': 1},
            ],
          },
        });
        return store;
      }))!;
      final overrides = (await tester.runAsync(
        () => testOverrides(store: store),
      ))!;
      final router = createRouter(initialLocation: AppRoutes.adminAccounts);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Grand écran : tableau et barre latérale, comme la maquette.
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Utilisateurs'), findsOneWidget);
      expect(find.text('Tous (2)'), findsOneWidget);
      expect(find.text('Actifs (1)'), findsOneWidget);
      expect(find.text('Désactivés (1)'), findsOneWidget);

      // Recherche locale, sans accents ni casse.
      await tester.enterText(find.byType(TextField), 'traore');
      await tester.pumpAndSettle();
      expect(find.text('Awa Traoré'), findsOneWidget);
      expect(find.text('Jean Dupont'), findsNothing);
      expect(find.text('Tous (1)'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Désactivés (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Awa Traoré'), findsNothing);
      expect(find.text('Jean Dupont'), findsOneWidget);
      await tester.tap(find.text('Tous (2)'));
      await tester.pumpAndSettle();

      // Ajout hors ligne : enregistré dans la file, affiché en attente.
      await tester.tap(find.text('Ajouter un utilisateur'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Prénom'),
        'Issa',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nom'),
        'Kaboré',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'E-mail'),
        'issa@test.local',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Mot de passe provisoire'),
        'Provisoire1',
      );
      await tester.tap(find.text('Rôle').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Particulier').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
      await tester.pumpAndSettle();

      expect(find.text('Issa Kaboré'), findsOneWidget);
      expect(find.text('En attente d’envoi'), findsOneWidget);
      expect(find.text('Tous (3)'), findsOneWidget);

      final actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
      expect(actions.single.kind, 'user.create');
      expect(actions.single.method, 'POST');
      expect(actions.single.body, containsPair('actor_id', 1));
      expect(actions.single.body, containsPair('email', 'issa@test.local'));
    },
  );

  testWidgets(
    'barre latérale : réservations, impact et administration hors ligne',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final store = (await tester.runAsync(() async {
        final store = await memoryStore();
        await store.saveSnapshot({
          'admin': {
            'users': users,
            'actors': [actors.first],
            'reservations': [
              {
                'id': 7,
                'offer_title': 'Panier de légumes',
                'donor_name': 'Restaurant Le Soleil',
                'beneficiary_name': 'Awa Traoré',
                'quantity': 2,
                'unit': 'kg',
                'status': 'confirmed',
                'created_at': '2026-10-01T10:00:00Z',
              },
              {
                'id': 8,
                'offer_title': 'Pain du jour',
                'donor_name': 'Boulangerie',
                'beneficiary_name': 'Issa Kaboré',
                'quantity': 5,
                'status': 'picked_up',
                'created_at': '2026-09-20T10:00:00Z',
              },
            ],
            'impact_global': {
              'as_of': '2026-10-03T08:00:00Z',
              'impact': {
                'pickups': 12,
                'items': 30,
                'food_kg': 48.5,
                'co2_kg': 120.2,
                'meals': 97,
                'users': 42,
              },
              'monthly': [
                for (var m = 1; m <= 12; m++)
                  {
                    'month': '2026-${m.toString().padLeft(2, '0')}',
                    'food_kg': m * 1.5,
                  },
              ],
              'by_category': [
                {
                  'category_name': 'Fruits et légumes',
                  'food_kg': 30,
                  'co2_kg': 60,
                },
              ],
            },
            'stats': {'categories_total': 6},
          },
        });
        return store;
      }))!;
      final overrides = (await tester.runAsync(
        () => testOverrides(store: store),
      ))!;
      final router = createRouter(initialLocation: AppRoutes.adminAccounts);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Réservations de toute la plateforme, filtrées et recherchées.
      await tester.tap(find.text('Réservations'));
      await tester.pumpAndSettle();
      expect(find.text('Toutes (2)'), findsOneWidget);
      expect(find.text('Panier de légumes'), findsOneWidget);
      expect(find.text('Confirmée'), findsOneWidget);
      await tester.tap(find.text('Retirées (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Panier de légumes'), findsNothing);
      expect(find.text('Pain du jour'), findsOneWidget);
      await tester.tap(find.text('Pain du jour'));
      await tester.pumpAndSettle();
      expect(find.text('Réservation n° 8'), findsOneWidget);
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();

      // Impact global : totaux et catégories.
      await tester.tap(find.text('Impact'));
      await tester.pumpAndSettle();
      expect(find.text('48,5 kg'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('Fruits et légumes'), findsOneWidget);

      // Administration : sections et compteurs.
      await tester.tap(find.text('Administration').first);
      await tester.pumpAndSettle();
      expect(find.text('Acteurs'), findsOneWidget);
      expect(find.text('1 acteur'), findsOneWidget);
      expect(find.text('6 catégories'), findsOneWidget);
      await tester.tap(find.text('Acteurs'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Acteurs'), findsOneWidget);
    },
  );

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
            {
              ...publishedOffer(id: 4, title: 'Riz sans compte'),
              'donor_id': null,
              'is_guest': 1,
              'contact_phone': '+226 70 12 34 56',
            },
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
        await tester.dragUntilVisible(
          find.text('Panier de mangues'),
          find.byType(CustomScrollView),
          const Offset(0, -200),
        );
        expect(find.text('250 F CFA'), findsOneWidget);
        await tester.dragUntilVisible(
          find.text('Pains du jour'),
          find.byType(CustomScrollView),
          const Offset(0, -200),
        );
        // Rayon illimité par défaut : l'offre lointaine aussi, après les proches.
        await tester.dragUntilVisible(
          find.text('Offre lointaine'),
          find.byType(CustomScrollView),
          const Offset(0, -200),
        );
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
        expect(find.text('À payer : 250 F CFA'), findsOneWidget);
        await tester.dragUntilVisible(
          find.text('Téléphone *'),
          find.byType(ListView),
          const Offset(0, -200),
        );
        await tester.dragUntilVisible(
          find.byTooltip('Plus'),
          find.byType(ListView),
          const Offset(0, 200),
        );

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
        expect(find.text('Téléphone obligatoire'), findsOneWidget);
      },
    );

    testWidgets('offre publiée sans compte : on appelle, on ne réserve pas', (
      tester,
    ) async {
      final store = await storeWithOffers(tester);
      await pumpRoute(tester, AppRoutes.offer('4'), store: store);

      expect(find.text('Riz sans compte'), findsOneWidget);
      expect(find.text('Réserver'), findsNothing);
      expect(find.text('Appeler le donateur'), findsOneWidget);
      expect(find.text('+226 70 12 34 56'), findsOneWidget);
    });

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

      await tester.ensureVisible(find.text('Prix réduit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prix réduit'));
      await tester.pumpAndSettle();
      expect(find.text('Comment payer ? *'), findsOneWidget);
      // Opérateurs du pays (Burkina Faso par défaut, position inconnue).
      expect(find.text('Opérateur (Burkina Faso)'), findsOneWidget);
      expect(find.text('+226'), findsWidgets);
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

    testWidgets('le logo ramène à l’écran de démarrage', (tester) async {
      await pumpRoute(tester, AppRoutes.home);

      await tester.tap(find.byTooltip('Retour à l’accueil'));
      await tester.pumpAndSettle();

      expect(find.text('Commencer'), findsOneWidget);
    });
  });
  testWidgets(
    'paramètres : quota sans compte modifié, publications interdites',
    (tester) async {
      final store = (await tester.runAsync(() async {
        final store = await memoryStore();
        await store.saveSnapshot({
          'admin': {
            'settings': {
              'guest_offer_max': 10,
              'guest_offer_window_hours': 1,
              'guest_reservation_max': 20,
              'guest_reservation_window_hours': 24,
            },
          },
        });
        return store;
      }))!;
      await pumpRoute(tester, AppRoutes.adminSettings, store: store);

      expect(find.text('Publications sans compte'), findsOneWidget);
      expect(find.text('Par jour'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, '20'), '5');
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('Interdites : compte obligatoire'), findsOneWidget);

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      final actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
      expect(actions.single.body, {
        'guest_offer_max': 0,
        'guest_offer_window_hours': 1,
        'guest_reservation_max': 5,
        'guest_reservation_window_hours': 24,
      });
    },
  );
  testWidgets(
    'mot de passe oublié : code par e-mail puis nouveau mot de passe',
    (tester) async {
      final server = FakeServer((request) async => jsonResponse(200, {}));
      final overrides = await tester.runAsync(screenOverrides);
      final router = createRouter(
        initialLocation: AppRoutes.forgotPasswordFor('awa@test.local'),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides!,
            dioProvider.overrideWithValue(Dio()..httpClientAdapter = server),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Recevoir un code'));
      await tester.pumpAndSettle();
      expect(server.requests.last.path, '/auth/password/forgot');
      expect(server.requests.last.data, {'email': 'awa@test.local'});

      await tester.enterText(
        find.widgetWithText(TextFormField, '••••••'),
        '123456',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '8 caractères, lettres et chiffres'),
        'nouveau123',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Le même mot de passe'),
        'nouveau123',
      );
      await tester.ensureVisible(find.text('Changer le mot de passe'));
      await tester.tap(find.text('Changer le mot de passe'));
      await tester.pumpAndSettle();

      expect(server.requests.last.path, '/auth/password/reset');
      expect(server.requests.last.data, {
        'email': 'awa@test.local',
        'code': '123456',
        'password': 'nouveau123',
      });
      expect(find.text('Connexion'), findsOneWidget);
    },
  );
}
