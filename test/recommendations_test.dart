import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/location/geo.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/recommendations/data/ai_refiner.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';
import 'package:repo_partage_plus/features/recommendations/domain/hybrid_recommender.dart';
import 'package:repo_partage_plus/features/recommendations/domain/local_ranker.dart';

import 'helpers.dart';

const here = Place(lat: 12.3714, lng: -1.5197, label: 'Ici', isCurrent: true);

Map<String, dynamic> offerAt(
  int id, {
  double km = 1,
  int expiresIn = 3,
  num price = 0,
  int categoryId = 1,
  String publisher = 'commercant',
}) {
  final base = publishedOffer(
    id: id,
    title: 'Offre $id',
    // ~111 km par degré de latitude.
    lat: here.lat + km / 111.2,
    lng: here.lng,
    price: price,
    categoryId: categoryId,
  );
  final now = DateTime.now();
  return {
    ...base,
    'publisher_type': publisher,
    'expiry_date': now
        .add(Duration(days: expiresIn))
        .toIso8601String()
        .substring(0, 10),
  };
}

List<int> ids(List<RankedOffer> ranked) => [for (final r in ranked) r.id];

List<RankedOffer> rank(
  List<Map<String, dynamic>> offers, {
  RecoPreferences preferences = const RecoPreferences(),
  UserHistory history = const UserHistory(),
  int? excludeDonorId,
}) => const LocalRanker().rank(
  offers,
  origin: here,
  preferences: preferences,
  history: history,
  now: DateTime.now(),
  excludeDonorId: excludeDonorId,
);

/// Faux service d'IA : renvoie l'ordre donné, ou échoue.
class FakeAi implements AiRefiner {
  FakeAi({this.order = const [], this.error});

  List<int> order;
  Object? error;
  final payloads = <Map<String, Object?>>[];

  @override
  Future<AiRefinement> refine(Map<String, Object?> payload) async {
    payloads.add(payload);
    if (error != null) throw error!;
    return AiRefinement(
      ranking: [for (final id in order) (id: id, reason: 'IA $id')],
      model: 'test',
    );
  }
}

void main() {
  group('distances et regroupement', () {
    test('haversine : 1° de latitude ≈ 111 km ; temps de marche', () {
      expect(haversineKm(12, -1.5, 13, -1.5), closeTo(111.2, 0.2));
      expect(haversineKm(12.37, -1.52, 12.37, -1.52), 0);
      // 1 km à vol d'oiseau → 1,3 km à pied à 4,5 km/h ≈ 17 min.
      expect(walkingMinutes(1), 17);
      expect(formatWalkingTime(5), '1 h 27 à pied');
    });

    test('offres proches regroupées, groupes triés par distance', () {
      final offers = [
        offerAt(1, km: 2.0),
        offerAt(2, km: 2.1),
        offerAt(3, km: 0.2),
        offerAt(4, km: 2.05),
      ];
      final clusters = clusterByProximity(
        offers,
        lat: (o) => (o['latitude'] as num).toDouble(),
        lng: (o) => (o['longitude'] as num).toDouble(),
        radiusKm: 0.5,
        originLat: here.lat,
        originLng: here.lng,
      );
      expect(clusters.map((c) => c.size), [1, 3]);
      expect(clusters.first.items.single['id'], 3);
      expect(
        clusters.last.distanceFrom(here.lat, here.lng),
        closeTo(2.05, 0.05),
      );
    });

    test('rayon de regroupement : plus petit quand on zoome', () {
      final far = clusterRadiusKmForZoom(10, 12.37);
      final near = clusterRadiusKmForZoom(16, 12.37);
      expect(far, greaterThan(near * 60));
      expect(near, closeTo(0.14, 0.02));
    });
  });

  group('score local', () {
    test('à critères égaux : la plus proche, puis la plus urgente', () {
      expect(ids(rank([offerAt(1, km: 8), offerAt(2, km: 0.5)])), [2, 1]);
      expect(ids(rank([offerAt(1, expiresIn: 10), offerAt(2, expiresIn: 0)])), [
        2,
        1,
      ]);
    });

    test('catégorie recherchée et type de publieur préféré', () {
      final offers = [
        offerAt(1, categoryId: 1, publisher: 'commercant'),
        offerAt(2, categoryId: 2, publisher: 'particulier'),
      ];
      expect(
        ids(rank(offers, preferences: const RecoPreferences(categoryIds: {2}))),
        [2, 1],
      );
      expect(
        ids(
          rank(
            offers,
            preferences: const RecoPreferences(publisherTypes: {'particulier'}),
          ),
        ),
        [2, 1],
      );
    });

    test('prix : gratuit favorisé, au-delà du maximum pénalisé', () {
      final ranked = rank([
        offerAt(1, price: 3000),
        offerAt(2, price: 0),
        offerAt(3, price: 400),
      ], preferences: const RecoPreferences(maxPrice: 1000));
      expect(ids(ranked), [2, 3, 1]);
      expect(ranked.first.reasons, contains('Gratuit'));
      expect(ranked.last.score.price, 0);
    });

    test('historique : la catégorie la plus réservée remonte', () {
      final history = buildHistory(const [], const [
        {'category_id': 2, 'offer_title': 'Pains'},
      ]);
      expect(
        ids(
          rank([
            offerAt(1, categoryId: 1),
            offerAt(2, categoryId: 2),
          ], history: history),
        ),
        [2, 1],
      );
    });

    test('ses propres offres et les offres indisponibles sont exclues', () {
      final expired = {...offerAt(3), 'status': 'completed'};
      final ranked = rank([
        offerAt(1),
        {...offerAt(2), 'donor_id': 42},
        expired,
      ], excludeDonorId: 42);
      expect(ids(ranked), [1]);
    });

    test('score sur 100, détaillé', () {
      final best = rank([offerAt(1, km: 0, expiresIn: 0)]).single;
      expect(best.score.total, inInclusiveRange(0, 100));
      expect(best.score.urgency, 1);
      expect(best.reasons, contains('Expire aujourd’hui'));
    });
  });

  group('affinage par IA', () {
    test('seules les 100 premières offres sont envoyées', () {
      final ranked = rank([for (var i = 1; i <= 130; i++) offerAt(i)]);
      final payload = buildAiPayload(
        ranked: ranked,
        preferences: const RecoPreferences(text: 'des légumes'),
        history: const UserHistory(),
        categories: const [],
      );
      expect(payload['candidates'], hasLength(aiCandidateLimit));
      expect(payload['preferences_text'], 'des légumes');
    });

    test('fusion : ordre de l’IA puis reste local ; id inconnus ignorés', () {
      final local = rank([offerAt(1, km: 0.1), offerAt(2), offerAt(3, km: 5)]);
      final merged = mergeRanking(
        local,
        const AiRefinement(
          ranking: [
            (id: 3, reason: 'Proche de vos goûts'),
            (id: 99, reason: null),
          ],
        ),
      );
      expect(ids(merged), [3, 1, 2]);
      expect(merged.first.aiReason, 'Proche de vos goûts');
      expect(merged[1].aiReason, isNull);
    });
  });

  group('moteur hybride et repli', () {
    late StreamController<bool> network;
    late FakeAi ai;
    late ProviderContainer container;

    Future<ProviderContainer> start({required bool online}) async {
      network = StreamController<bool>.broadcast();
      ai = FakeAi(order: const [3]);
      final store = await memoryStore();
      await store.saveSnapshot({
        'offers': [offerAt(1, km: 0.1), offerAt(2), offerAt(3, km: 5)],
      });
      final server = FakeServer((request) async => jsonResponse(200, {}));
      container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          onlineProvider.overrideWith((ref) async* {
            yield online;
            yield* network.stream;
          }),
          locationGatewayProvider.overrideWithValue(FakeLocation()),
          dioProvider.overrideWithValue(Dio()..httpClientAdapter = server),
          aiRefinerProvider.overrideWithValue(ai),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await network.close();
      });
      // Démarre la synchronisation, la position et la lecture des offres.
      container.listen(syncControllerProvider, (_, _) {});
      container.listen(recommendationsProvider, (_, _) {});
      await container.read(originProvider.notifier).useCurrentPosition();
      await pumpEventQueue();
      return container;
    }

    ({List<RankedOffer> items, RecoSource source}) result() =>
        container.read(recommendationsProvider);

    test('hors ligne : classement local, IA jamais appelée', () async {
      await start(online: false);
      await container.read(recommendationsControllerProvider.notifier).refine();

      expect(ai.payloads, isEmpty);
      expect(result().source, RecoSource.local);
      expect(ids(result().items), [1, 2, 3]);
      expect(
        container.read(recommendationsControllerProvider).notice,
        contains('Hors ligne'),
      );
    });

    test('en ligne : l’ordre de l’IA est appliqué', () async {
      await start(online: true);
      await container.read(recommendationsControllerProvider.notifier).refine();

      expect(ai.payloads, hasLength(1));
      expect(result().source, RecoSource.ai);
      expect(ids(result().items), [3, 1, 2]);
    });

    test('IA en erreur : repli sur le score local, sans exception', () async {
      await start(online: true);
      ai.error = const AiUnavailable('Service d’IA indisponible');
      await container.read(recommendationsControllerProvider.notifier).refine();

      expect(result().source, RecoSource.local);
      expect(ids(result().items), [1, 2, 3]);
      expect(
        container.read(recommendationsControllerProvider).notice,
        'Service d’IA indisponible : classement local',
      );

      ai.error = StateError('erreur imprévue');
      await container.read(recommendationsControllerProvider.notifier).refine();
      expect(result().source, RecoSource.local);
    });

    test(
      'coupure puis retour du réseau : local, puis affinage relancé',
      () async {
        await start(online: true);
        final controller = container.read(
          recommendationsControllerProvider.notifier,
        );
        await controller.refine();
        expect(result().source, RecoSource.ai);

        network.add(false);
        await pumpEventQueue();
        expect(result().source, RecoSource.local);

        network.add(true);
        await pumpEventQueue();
        expect(ai.payloads, hasLength(2));
        expect(result().source, RecoSource.ai);
      },
    );
  });
}
