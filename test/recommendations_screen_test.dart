import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/features/recommendations/data/ai_refiner.dart';
import 'package:repo_partage_plus/features/recommendations/data/voice_input.dart';

import 'helpers.dart';
import 'recommendations_test.dart' show FakeAi;

/// Dictée refusée (micro non autorisé).
class DeniedVoice implements VoiceInput {
  @override
  Future<bool> start({
    required void Function(String text, bool done) onResult,
  }) async => false;

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('hors ligne : recommandations locales, dictée refusée gérée', (
    tester,
  ) async {
    final store = (await tester.runAsync(memoryStore))!;
    await tester.runAsync(
      () => store.saveSnapshot({
        'categories': [
          {'id': 1, 'name': 'Fruits et légumes', 'icon': 'eco'},
        ],
        'offers': [
          {
            ...publishedOffer(id: 1, title: 'Panier de mangues'),
            'publisher_type': 'commercant',
          },
        ],
      }),
    );
    final ai = FakeAi();
    final overrides = await tester.runAsync(() => testOverrides(store: store));
    final router = createRouter(initialLocation: AppRoutes.recommendations);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides!,
          aiRefinerProvider.overrideWithValue(ai),
          voiceInputProvider.overrideWithValue(DeniedVoice()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bonjour !'), findsOneWidget);
    expect(find.textContaining('Hors ligne'), findsWidgets);
    expect(ai.payloads, isEmpty);

    await tester.dragUntilVisible(
      find.text('Panier de mangues'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(find.textContaining('%'), findsWidgets);

    await tester.dragUntilVisible(
      find.byTooltip('Dicter'),
      find.byType(ListView),
      const Offset(0, 200),
    );
    await tester.tap(find.byTooltip('Dicter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Dictée indisponible'), findsOneWidget);
  });
}
