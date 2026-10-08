import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';

import 'helpers.dart';

Future<(LocalStore, FakeAuthGateway)> _pump(
  WidgetTester tester,
  String location, {
  bool withUnsent = false,
}) async {
  final store = (await tester.runAsync(() async {
    final store = await memoryStore();
    await store.saveToken('jeton');
    await store.saveSnapshot({
      'profile': {
        'id': 1,
        'name': 'Admin Partage',
        'email': 'admin@demo.local',
        'role': 'admin',
      },
    });
    if (withUnsent) {
      await Outbox(store.db).add(
        PendingAction(
          kind: 'message.send',
          method: 'POST',
          path: '/messages',
          body: {'body': 'Bonjour'},
          label: 'Message',
        ),
      );
    }
    return store;
  }))!;
  final gateway = FakeAuthGateway();
  final overrides = (await tester.runAsync(() => testOverrides(store: store)))!;
  final router = createRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        initialTokenProvider.overrideWithValue('jeton'),
        authGatewayProvider.overrideWithValue(gateway),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (store, gateway);
}

void main() {
  testWidgets('barre latérale admin : déconnexion avec avertissement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final (store, gateway) = await _pump(
      tester,
      AppRoutes.adminManage,
      withUnsent: true,
    );
    expect(find.text('Admin Partage'), findsOneWidget);

    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('1 modification pas encore envoyée'),
      findsOneWidget,
    );

    // Annuler : rien n'est effacé.
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(store.readToken), 'jeton');

    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Déconnecter quand même'));
    await tester.pumpAndSettle();

    expect(await tester.runAsync(store.readToken), isNull);
    expect(await tester.runAsync(() => store.readSnapshot('profile')), isNull);
    expect(gateway.calls, contains('signOut'));
    expect(find.text('Connexion'), findsWidgets);
  });

  testWidgets('menu (téléphone) : bouton « Se déconnecter »', (tester) async {
    final (store, _) = await _pump(tester, AppRoutes.notifications);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();
    expect(
      find.text('Les données enregistrées sur cet appareil seront effacées.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Se déconnecter'));
    await tester.pumpAndSettle();

    expect(await tester.runAsync(store.readToken), isNull);
  });
}
