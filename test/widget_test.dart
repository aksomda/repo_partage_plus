import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
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
};

Future<List<Override>> screenOverrides() async => [
  ...await testOverrides(),
  authGatewayProvider.overrideWithValue(FakeAuthGateway()),
  signupActorsProvider.overrideWith((ref) async => actors),
  adminUsersProvider.overrideWith((ref, filters) async => users),
];

Future<void> pumpRoute(WidgetTester tester, String location) async {
  final overrides = await tester.runAsync(screenOverrides);
  final router = createRouter(initialLocation: location);
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
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('champs obligatoires signalés', (tester) async {
      await pumpRoute(tester, AppRoutes.register);
      await tester.tap(find.text('Particulier'));
      await tester.pumpAndSettle();

      final submit = find.text('Créer mon compte');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.text('Nom obligatoire'), findsOneWidget);
      expect(find.text('Sexe obligatoire'), findsOneWidget);
      expect(find.text('Âge obligatoire'), findsOneWidget);
      expect(find.text('Adresse e-mail obligatoire'), findsOneWidget);
      expect(find.text('8 caractères minimum'), findsOneWidget);
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
}
