import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/features/recommendations/data/ai_refiner.dart';
import 'package:repo_partage_plus/features/recommendations/data/offer_search_agent.dart';
import 'package:repo_partage_plus/features/recommendations/data/voice_input.dart';
import 'package:repo_partage_plus/features/recommendations/data/voice_recorder.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';

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

/// Micro refusé.
class DeniedRecorder implements VoiceRecorder {
  @override
  Future<bool> start() async => false;

  @override
  Future<RecordedAudio?> stop() async => null;

  @override
  Future<void> cancel() async {}
}

/// Enregistrement factice de quelques octets.
class FakeRecorder implements VoiceRecorder {
  var recording = false;

  @override
  Future<bool> start() async => recording = true;

  @override
  Future<RecordedAudio?> stop() async {
    recording = false;
    return (bytes: Uint8List.fromList([1, 2, 3]), mime: 'audio/mp4');
  }

  @override
  Future<void> cancel() async => recording = false;
}

/// Agent IA factice : retranscrit « je veux du riz gras », garde [keep].
class FakeAgent implements OfferSearchAgent {
  FakeAgent(this.keep);

  final List<int> keep;
  final calls = <({bool audio, String? text, List<Json> candidates})>[];

  @override
  bool get understandsAudio => true;

  @override
  Future<OfferSearchResult> search({
    RecordedAudio? audio,
    String? text,
    required List<Json> candidates,
  }) async {
    calls.add((audio: audio != null, text: text, candidates: candidates));
    return OfferSearchResult(
      request: text ?? 'je veux du riz gras',
      keepIds: keep,
      engine: 'Gemini',
    );
  }
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
          voiceRecorderProvider.overrideWithValue(DeniedRecorder()),
          offerSearchAgentProvider.overrideWithValue(FakeAgent(const [])),
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
      find.byTooltip('Parler'),
      find.byType(ListView),
      const Offset(0, 200),
    );
    // Micro refusé à l'enregistrement, puis à la dictée : signalé.
    await tester.tap(find.byTooltip('Parler'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Dictée indisponible'), findsOneWidget);
  });

  testWidgets('voix : enregistrée, retranscrite et filtrée par l’agent IA', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(memoryStore))!;
    await tester.runAsync(
      () => store.saveSnapshot({
        'categories': [
          {'id': 1, 'name': 'Plats cuisinés', 'icon': 'restaurant'},
        ],
        'offers': [
          publishedOffer(id: 1, title: 'Pain du jour'),
          publishedOffer(id: 2, title: '10 plats de riz gras'),
        ],
      }),
    );
    final recorder = FakeRecorder();
    final agent = FakeAgent(const [2]);
    final overrides = await tester.runAsync(() => testOverrides(store: store));
    final router = createRouter(initialLocation: AppRoutes.recommendations);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides!,
          aiRefinerProvider.overrideWithValue(FakeAi()),
          voiceRecorderProvider.overrideWithValue(recorder),
          offerSearchAgentProvider.overrideWithValue(agent),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pain du jour'), findsOneWidget);

    await tester.tap(find.byTooltip('Parler'));
    await tester.pump();
    expect(recorder.recording, isTrue);
    expect(find.textContaining('Enregistrement 0:0'), findsOneWidget);

    await tester.tap(find.byTooltip('Envoyer l’enregistrement'));
    await tester.pumpAndSettle();

    // L'audio part à l'agent avec les offres candidates.
    expect(agent.calls.single.audio, isTrue);
    expect(
      agent.calls.single.candidates.map((c) => c['id']),
      containsAll([1, 2]),
    );
    // Demande retranscrite dans le champ ; seule l'offre retenue reste.
    expect(find.text('je veux du riz gras'), findsOneWidget);
    expect(find.text('« je veux du riz gras »'), findsOneWidget);
    expect(find.text('10 plats de riz gras'), findsOneWidget);
    expect(find.text('Pain du jour'), findsNothing);

    await tester.tap(find.text('Tout afficher'));
    await tester.pumpAndSettle();
    expect(find.text('Pain du jour'), findsOneWidget);
  });

  group('agent de recherche', () {
    test(
      'agent du serveur : audio et id envoyés, réponse lue, 503 rattrapé',
      () async {
        final requests = <Map<String, dynamic>>[];
        var status = 200;
        final dio = Dio(BaseOptions(baseUrl: 'http://api.test/api'))
          ..httpClientAdapter = FakeServer((request) async {
            requests.add(request.data as Map<String, dynamic>);
            return status == 200
                ? jsonResponse(200, {
                    'transcript': 'Je veux du riz gras',
                    'keep_ids': [1],
                    'summary': 'Du riz gras',
                    'engine': 'Groq',
                  })
                : jsonResponse(status, {'error': 'IA vocale indisponible'});
          });
        final agent = ServerOfferSearchAgent(dio);
        final result = await agent.search(
          audio: (bytes: Uint8List.fromList([1, 2]), mime: 'audio/mp4'),
          candidates: [
            {'id': 1, 'titre': 'Riz gras', 'distance_km': 0.4},
            {'id': 2, 'titre': 'Pain'},
          ],
        );
        expect(result.request, 'Je veux du riz gras');
        expect(result.keepIds, [1]);
        expect(result.engine, 'Groq');
        expect(requests.single['audio'], 'data:audio/mp4;base64,AQI=');
        // Seuls les id et distances partent : le serveur relit les offres.
        expect(requests.single['candidates'], [
          {'id': 1, 'distance_km': 0.4},
          {'id': 2},
        ]);

        status = 503;
        expect(
          () => agent.search(
            text: 'riz',
            candidates: [
              {'id': 1},
            ],
          ),
          throwsA(isA<OfferSearchUnavailable>()),
        );
      },
    );

    final candidates = [
      {'id': 1, 'title': '10 plats de riz gras', 'price': 0},
      {'id': 2, 'title': 'Riz sauce arachide', 'price': 500},
      {'id': 3, 'title': '10 mise de pain non vendu', 'price': 0},
      {'id': 4, 'title': 'Panier de mangues', 'price': 250},
    ];

    test(
      'mots-clés sur l’appareil : garde les offres les plus proches',
      () async {
        const agent = KeywordOfferSearchAgent();
        final rizGras = await agent.search(
          text: 'je veux du riz gras',
          candidates: candidates,
        );
        expect(rizGras.keepIds, [1]);
        final mangues = await agent.search(
          text: 'Des mangues pas trop chères',
          candidates: candidates,
        );
        expect(mangues.keepIds, [4]);
        final gratuit = await agent.search(
          text: 'du riz gratuit',
          candidates: candidates,
        );
        expect(gratuit.keepIds, [1]);
      },
    );

    test(
      'IA indisponible : mots-clés pour le texte, dictée pour l’audio',
      () async {
        // Serveur et Gemini en panne.
        final agent = FallbackOfferSearchAgent([
          _DownAgent(),
          _DownAgent(),
        ], const KeywordOfferSearchAgent());
        final text = await agent.search(
          text: 'riz gras',
          candidates: candidates,
        );
        expect(text.keepIds, [1]);
        expect(text.engine, 'l’appareil');
        expect(
          () => agent.search(
            audio: (bytes: Uint8List(3), mime: 'audio/mp4'),
            candidates: candidates,
          ),
          throwsA(isA<OfferSearchUnavailable>()),
        );
      },
    );
  });
}

class _DownAgent implements OfferSearchAgent {
  @override
  bool get understandsAudio => true;

  @override
  Future<OfferSearchResult> search({
    RecordedAudio? audio,
    String? text,
    required List<Json> candidates,
  }) async => throw const OfferSearchUnavailable('Hors ligne');
}
