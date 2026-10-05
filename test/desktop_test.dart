import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/firebase/firebase_rest.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';
import 'package:repo_partage_plus/features/recommendations/data/ai_refiner.dart';

import 'helpers.dart';

const config = FirebaseRestConfig(
  apiKey: 'cle-web',
  projectId: 'partageplus-f8840',
);

Map<String, dynamic> bodyOf(RequestOptions request) =>
    jsonDecode(jsonEncode(request.data)) as Map<String, dynamic>;

ResponseBody googleError(String message) => jsonResponse(400, {
  'error': {'code': 400, 'message': message},
});

/// Passerelle Firebase absente (Firebase non configuré).
class UnconfiguredGateway extends FakeAuthGateway {
  @override
  Future<String> createAccount(String email, String password) async =>
      throw const FirebaseAuthFailure('not-configured', 'Non configuré');
}

class FixedAi implements AiRefiner {
  FixedAi(this.result);

  final Object result;
  var calls = 0;

  @override
  Future<AiRefinement> refine(Map<String, Object?> payload) async {
    calls++;
    if (result is AiUnavailable) throw result;
    if (result is Exception) throw result;
    return result as AiRefinement;
  }
}

void main() {
  late FakeServer server;
  late Dio dio;

  setUp(() {
    server = FakeServer((request) async => jsonResponse(404, {}));
    dio = Dio()..httpClientAdapter = server;
  });

  group('Firebase Auth par HTTP (Windows / Linux / macOS)', () {
    test('création de compte : jeton renvoyé, clé web envoyée', () async {
      server.handler = (request) async =>
          jsonResponse(200, {'idToken': 'jeton-firebase', 'localId': 'uid'});

      final token = await RestAuthGateway(
        dio,
        config,
      ).createAccount('awa@test.local', 'motdepasse1');

      expect(token, 'jeton-firebase');
      final request = server.requests.single;
      expect(request.uri.path, '/v1/accounts:signUp');
      expect(request.uri.queryParameters['key'], 'cle-web');
      expect(bodyOf(request)['returnSecureToken'], isTrue);
    });

    test('erreurs de l’API traduites comme le SDK', () async {
      final gateway = RestAuthGateway(dio, config);
      Future<String> codeFor(String message) async {
        server.handler = (_) async => googleError(message);
        try {
          await gateway.signIn('awa@test.local', 'x');
        } on FirebaseAuthFailure catch (error) {
          return error.code;
        }
        return 'aucune';
      }

      expect(await codeFor('EMAIL_EXISTS'), 'email-already-in-use');
      expect(await codeFor('INVALID_LOGIN_CREDENTIALS'), 'invalid-credential');
      expect(await codeFor('USER_DISABLED'), 'user-disabled');
      expect(await codeFor('WEAK_PASSWORD : 6 caractères'), 'weak-password');
      expect(await codeFor('OPERATION_NOT_ALLOWED'), 'not-configured');
    });

    test(
      'sans configuration Firebase : not-configured, aucune requête',
      () async {
        await expectLater(
          RestAuthGateway(dio, null).signIn('a@b.c', 'x'),
          throwsA(
            isA<FirebaseAuthFailure>().having(
              (e) => e.code,
              'code',
              'not-configured',
            ),
          ),
        );
        expect(server.requests, isEmpty);
      },
    );

    test('réseau coupé : message clair', () async {
      server.handler = networkDown;
      await expectLater(
        RestAuthGateway(dio, config).signIn('a@b.c', 'x'),
        throwsA(
          isA<FirebaseAuthFailure>().having(
            (e) => e.code,
            'code',
            'network-request-failed',
          ),
        ),
      );
    });

    test('session anonyme : créée une fois, puis renouvelée', () async {
      final store = await memoryStore();
      server.handler = (request) async =>
          request.uri.host == 'identitytoolkit.googleapis.com'
          ? jsonResponse(200, {
              'idToken': 'jeton-1',
              'refreshToken': 'refresh-1',
              'expiresIn': '0',
            })
          : jsonResponse(200, {
              'id_token': 'jeton-2',
              'refresh_token': 'refresh-2',
              'expires_in': '3600',
            });
      final session = AnonymousRestSession(
        dio: dio,
        config: config,
        store: store,
      );

      expect(await session.idToken(), 'jeton-1');
      // Expiré immédiatement : renouvellement avec le jeton de rafraîchissement.
      expect(await session.idToken(), 'jeton-2');
      expect(await session.idToken(), 'jeton-2');
      expect(server.requests.map((r) => r.uri.host), [
        'identitytoolkit.googleapis.com',
        'securetoken.googleapis.com',
      ]);
      expect(
        await store.readSetting<String>('firebase_anonymous_refresh'),
        'refresh-2',
      );
    });
  });

  group('inscription sans Firebase', () {
    test(
      'compte local : e-mail et mot de passe envoyés à l’API (MySQL)',
      () async {
        server.handler = (request) async => jsonResponse(201, {
          'user': {'status': 'pending'},
        });
        final store = await memoryStore();
        final container = ProviderContainer(
          overrides: [
            localStoreProvider.overrideWithValue(store),
            authGatewayProvider.overrideWithValue(UnconfiguredGateway()),
            dioProvider.overrideWithValue(dio),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(authRepositoryProvider)
            .register(
              const Registration(
                actorId: 1,
                lastName: 'Ouédraogo',
                firstName: 'Ali',
                gender: 'male',
                age: 30,
                email: 'ali@test.local',
                phone: '+226 70 11 22 33',
                password: 'motdepasse1',
              ),
            );

        final body = bodyOf(server.requests.single);
        expect(server.requests.single.path, '/auth/register');
        expect(body['email'], 'ali@test.local');
        expect(body['password'], 'motdepasse1');
        expect(body.containsKey('id_token'), isFalse);
        expect(body['first_name'], 'Ali');
        expect(body['actor_id'], 1);
      },
    );
  });

  group('IA : serveur et repli', () {
    final payload = <String, Object?>{
      'preferences_text': 'des fruits',
      'origin': {'lat': 12.37, 'lng': -1.52},
      'history': {
        'recent_titles': ['Pains'],
      },
      'candidates': [
        {'id': 3, 'title': 'Mangues', 'local_score': 81.5},
        {'id': 7, 'title': 'Riz', 'local_score': 60.0},
      ],
    };

    test(
      'IA du serveur : seulement des id, position et consultations',
      () async {
        server.handler = (request) async => jsonResponse(200, {
          'ranking': [
            {'id': 7, 'reason': 'Proche'},
          ],
          'source': 'server',
        });

        final result = await ServerAiRefiner(dio).refine(payload);

        expect(result.ranking.single.id, 7);
        final body = bodyOf(server.requests.single);
        expect(server.requests.single.path, '/recommendations/refine');
        expect(body['candidates'], [
          {'id': 3, 'local_score': 81.5},
          {'id': 7, 'local_score': 60.0},
        ]);
        expect(body['latitude'], 12.37);
        expect(body['recent_titles'], ['Pains']);
        expect(jsonEncode(body), isNot(contains('Mangues')));
      },
    );

    test(
      'IA du serveur non configurée : AiUnavailable avec le message',
      () async {
        server.handler = (request) async =>
            jsonResponse(503, {'error': 'IA non configurée sur le serveur'});
        await expectLater(
          ServerAiRefiner(dio).refine(payload),
          throwsA(
            isA<AiUnavailable>().having(
              (e) => e.message,
              'message',
              'IA non configurée sur le serveur',
            ),
          ),
        );
      },
    );

    test('repli : Cloud Function en échec → IA du serveur', () async {
      const ok = AiRefinement(ranking: [(id: 3, reason: null)]);
      final cloud = FixedAi(const AiUnavailable('Firebase absent'));
      final local = FixedAi(ok);

      final result = await FallbackAiRefiner([cloud, local]).refine(payload);

      expect(result.ranking.single.id, 3);
      expect(cloud.calls, 1);
      expect(local.calls, 1);
    });

    test(
      'toutes les IA en échec : dernière erreur, jamais de plantage',
      () async {
        await expectLater(
          FallbackAiRefiner([
            FixedAi(const AiUnavailable('Firebase absent')),
            FixedAi(StateError('inattendu')),
          ]).refine(payload),
          throwsA(isA<AiUnavailable>()),
        );
      },
    );

    test(
      'Cloud Function en HTTPS : jeton anonyme et format « callable »',
      () async {
        final store = await memoryStore();
        server.handler = (request) async {
          if (request.uri.host == 'identitytoolkit.googleapis.com') {
            return jsonResponse(200, {
              'idToken': 'jeton-anonyme',
              'refreshToken': 'r',
              'expiresIn': '3600',
            });
          }
          return jsonResponse(200, {
            'result': {
              'ranking': [
                {'id': 3, 'reason': 'Fruits'},
              ],
            },
          });
        };

        final result = await CallableRestAiRefiner(
          dio: dio,
          config: config,
          session: AnonymousRestSession(dio: dio, config: config, store: store),
        ).refine(payload);

        expect(result.ranking.single.id, 3);
        final call = server.requests.last;
        expect(
          call.uri.toString(),
          'https://europe-west1-partageplus-f8840.cloudfunctions.net/'
          'refineRecommendationsAi',
        );
        expect(call.headers['Authorization'], 'Bearer jeton-anonyme');
        expect(bodyOf(call)['data'], isA<Map>());
      },
    );
  });
}
