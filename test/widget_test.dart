import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';

import 'helpers.dart';

void main() {
  testWidgets("L'application démarre sur l'écran de démarrage", (tester) async {
    final overrides = await tester.runAsync(testOverrides);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides!, child: const RepasPartageApp()),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Démarrage'), findsOneWidget);
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
      final router = createRouter(initialLocation: entry.location);
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, entry.title), findsOneWidget);
    });
  }
}
