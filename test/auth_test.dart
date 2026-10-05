import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';

import 'helpers.dart';

const registration = Registration(
  actorId: 1,
  lastName: 'Traoré',
  firstName: 'Awa',
  gender: 'female',
  age: 28,
  email: 'awa@test.local',
  phone: '+226 70 00 00 00',
  password: 'motdepasse1',
);

Map<String, dynamic> session(String email, {String role = 'beneficiary'}) => {
  'token': 'jwt-$email',
  'user': {'id': 7, 'email': email, 'role': role, 'status': 'active'},
};

void main() {
  late FakeAuthGateway firebase;
  late FakeServer server;
  late ProviderContainer container;

  AuthRepository repository() => container.read(authRepositoryProvider);
  Map<String, dynamic> bodyOf(String path) => jsonDecode(
    jsonEncode(server.requests.lastWhere((r) => r.path == path).data),
  );

  setUp(() async {
    firebase = FakeAuthGateway();
    server = FakeServer((request) async {
      if (request.path == '/sync') return jsonResponse(200, {});
      return jsonResponse(404, {'error': 'Route inconnue'});
    });
    final store = await memoryStore();
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        onlineProvider.overrideWith((ref) => Stream.value(false)),
        authGatewayProvider.overrideWithValue(firebase),
        dioProvider.overrideWithValue(Dio()..httpClientAdapter = server),
      ],
    );
    addTearDown(container.dispose);
  });

  /// Attend la synchronisation lancée après l'ouverture de session.
  Future<void> settle() =>
      container.read(syncControllerProvider.notifier).syncNow();

  group('inscription', () {
    test(
      'compte Firebase créé, profil envoyé avec le jeton, sans session',
      () async {
        server.handler = (request) async => jsonResponse(201, {
          'user': {'status': 'pending'},
        });

        await repository().register(registration);

        expect(firebase.accounts, contains('awa@test.local'));
        final body = bodyOf('/auth/register');
        expect(body['id_token'], 'token-awa@test.local');
        expect(body['actor_id'], 1);
        expect(body['gender'], 'female');
        expect(body['age'], 28);
        // Gardé haché par l'API : connexion quand Firebase est injoignable.
        expect(body['password'], 'motdepasse1');
        expect(firebase.calls.last, 'signOut');
        expect(container.read(authTokenProvider), isNull);
      },
    );

    test('profil refusé : le compte Firebase créé est supprimé', () async {
      server.handler = (request) async =>
          jsonResponse(409, {'error': 'Un compte existe déjà'});

      await expectLater(
        repository().register(registration),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Un compte existe déjà',
          ),
        ),
      );
      expect(firebase.calls, containsAllInOrder(['create', 'delete']));
      expect(firebase.accounts, isEmpty);
    });

    test(
      'réponse perdue (délai dépassé) : le compte Firebase est conservé',
      () async {
        server.handler = (request) async => throw DioException.receiveTimeout(
          timeout: const Duration(seconds: 30),
          requestOptions: request,
        );

        await expectLater(
          repository().register(registration),
          throwsA(
            isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue),
          ),
        );
        // Le profil a pu être enregistré : le compte doit rester utilisable.
        expect(firebase.calls, isNot(contains('delete')));
        expect(firebase.accounts, contains('awa@test.local'));
      },
    );

    test('erreur serveur (5xx) : le compte Firebase est conservé', () async {
      server.handler = (request) async =>
          jsonResponse(500, {'error': 'Erreur interne'});

      await expectLater(
        repository().register(registration),
        throwsA(isA<ApiException>()),
      );
      expect(firebase.calls, isNot(contains('delete')));
      expect(firebase.accounts, contains('awa@test.local'));
    });

    test(
      'compte existant : code de réinitialisation envoyé, sans suppression',
      () async {
        firebase.accounts['awa@test.local'] = 'autre-motdepasse1';
        server.handler = (request) async =>
            request.path == '/auth/password/forgot'
            ? jsonResponse(200, {})
            : jsonResponse(404, {'error': 'Route inconnue'});

        await expectLater(
          repository().register(registration),
          throwsA(
            isA<AccountExistsException>()
                .having((e) => e.email, 'email', 'awa@test.local')
                .having((e) => e.resetSent, 'resetSent', isTrue),
          ),
        );
        expect(bodyOf('/auth/password/forgot'), {'email': 'awa@test.local'});
        expect(firebase.calls, isNot(contains('delete')));
        expect(firebase.accounts, contains('awa@test.local'));
      },
    );

    test(
      'compte Firebase orphelin, autre mot de passe : libéré puis recréé',
      () async {
        firebase.accounts['awa@test.local'] = 'ancien-motdepasse1';
        server.handler = (request) async {
          if (request.path == '/auth/release-orphan') {
            // Le serveur supprime le compte Firebase sans profil.
            firebase.accounts.remove('awa@test.local');
            return jsonResponse(200, const {});
          }
          return jsonResponse(201, {
            'user': {'status': 'pending'},
          });
        };

        await repository().register(registration);

        expect(bodyOf('/auth/release-orphan'), {'email': 'awa@test.local'});
        expect(firebase.accounts['awa@test.local'], 'motdepasse1');
        expect(bodyOf('/auth/register')['id_token'], 'token-awa@test.local');
      },
    );

    test(
      'profil déjà enregistré (409 email_taken) : réinitialisation',
      () async {
        firebase.accounts['awa@test.local'] = 'motdepasse1';
        server.handler = (request) async =>
            request.path == '/auth/password/forgot'
            ? jsonResponse(200, {})
            : jsonResponse(409, {
                'error': 'Un compte existe déjà',
                'details': {'code': 'email_taken'},
              });

        await expectLater(
          repository().register(registration),
          throwsA(
            isA<AccountExistsException>().having(
              (e) => e.resetSent,
              'resetSent',
              isTrue,
            ),
          ),
        );
        expect(bodyOf('/auth/password/forgot'), {'email': 'awa@test.local'});
        expect(firebase.accounts, contains('awa@test.local'));
      },
    );

    test(
      'inscription interrompue : reprise avec le compte Firebase existant',
      () async {
        firebase.accounts['awa@test.local'] = 'motdepasse1';
        server.handler = (request) async =>
            jsonResponse(503, {'error': 'Panne'});

        await expectLater(
          repository().register(registration),
          throwsA(anything),
        );
        // Compte existant avant cette tentative : jamais supprimé.
        expect(firebase.calls, isNot(contains('delete')));
        expect(firebase.accounts, contains('awa@test.local'));
      },
    );
  });

  group('activation et connexion', () {
    test('le bon code ouvre la session', () async {
      server.handler = (request) async => request.path == '/auth/verify-email'
          ? jsonResponse(200, session('awa@test.local'))
          : jsonResponse(200, {});

      await repository().verifyEmail('awa@test.local', '123456');
      await settle();

      expect(bodyOf('/auth/verify-email'), {
        'email': 'awa@test.local',
        'code': '123456',
      });
      expect(container.read(authTokenProvider), 'jwt-awa@test.local');
    });

    test('connexion : jeton Firebase échangé contre une session API', () async {
      firebase.accounts['awa@test.local'] = 'motdepasse1';
      server.handler = (request) async => request.path == '/auth/firebase'
          ? jsonResponse(200, session('awa@test.local'))
          : jsonResponse(200, {});

      await repository().login('awa@test.local', 'motdepasse1');
      await settle();

      expect(bodyOf('/auth/firebase'), {
        'id_token': 'token-awa@test.local',
        'password': 'motdepasse1',
      });
      expect(container.read(authTokenProvider), 'jwt-awa@test.local');
      expect(firebase.calls.last, 'signOut');
    });

    group('reconnexion après une session refusée', () {
      Future<LocalStore> withPendingMessage(int previousId) async {
        final store = container.read(localStoreProvider);
        await store.saveSnapshot({
          'profile': {'id': previousId, 'email': 'awa@test.local'},
        });
        await Outbox(store.db).add(
          PendingAction(
            kind: 'message.send',
            method: 'POST',
            path: '/messages',
            label: 'Message',
            body: {'body': 'Bonjour'},
          ),
        );
        firebase.accounts['awa@test.local'] = 'motdepasse1';
        // Session acceptée ; le reste du serveur indisponible : l'action
        // reste dans la file, on peut vérifier qu'elle n'a pas été effacée.
        server.handler = (request) async => request.path == '/auth/firebase'
            ? jsonResponse(200, session('awa@test.local'))
            : jsonResponse(503, {});
        return store;
      }

      test('même compte : les actions en attente sont gardées', () async {
        final store = await withPendingMessage(7);
        await repository().login('awa@test.local', 'motdepasse1');
        await settle();
        expect(await Outbox(store.db).all(), hasLength(1));
      });

      test('autre compte : les actions de l’ancien sont effacées', () async {
        final store = await withPendingMessage(99);
        await repository().login('awa@test.local', 'motdepasse1');
        await settle();
        expect(await Outbox(store.db).all(), isEmpty);
        expect(container.read(authTokenProvider), 'jwt-awa@test.local');
      });
    });

    test('compte non activé : AccountPendingException avec l’e-mail', () async {
      firebase.accounts['awa@test.local'] = 'motdepasse1';
      server.handler = (request) async => jsonResponse(403, {
        'error': 'Compte non activé',
        'details': {'code': 'account_pending', 'email': 'awa@test.local'},
      });

      await expectLater(
        repository().login('awa@test.local', 'motdepasse1'),
        throwsA(
          isA<AccountPendingException>().having(
            (e) => e.email,
            'email',
            'awa@test.local',
          ),
        ),
      );
      expect(container.read(authTokenProvider), isNull);
    });

    test('compte désactivé : message du serveur', () async {
      firebase.accounts['awa@test.local'] = 'motdepasse1';
      server.handler = (request) async => jsonResponse(403, {
        'error': 'Compte désactivé par l’administrateur',
        'details': {'code': 'account_suspended'},
      });

      await expectLater(
        repository().login('awa@test.local', 'motdepasse1'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'account_suspended',
          ),
        ),
      );
    });

    test(
      'compte de démo inconnu de Firebase : connexion directe par l’API',
      () async {
        server.handler = (request) async => request.path == '/auth/login'
            ? jsonResponse(200, session('admin@demo.local', role: 'admin'))
            : jsonResponse(200, {});

        await repository().login('admin@demo.local', 'Demo1234!');
        await settle();

        expect(bodyOf('/auth/login')['email'], 'admin@demo.local');
        expect(container.read(authTokenProvider), 'jwt-admin@demo.local');
      },
    );
  });

  group('Firebase injoignable, API disponible', () {
    test('connexion par l’API avec le mot de passe gardé dans MySQL', () async {
      firebase.down = true;
      server.handler = (request) async => request.path == '/auth/login'
          ? jsonResponse(200, session('awa@test.local'))
          : jsonResponse(200, {});

      await repository().login('awa@test.local', 'motdepasse1');
      await settle();

      expect(bodyOf('/auth/login')['password'], 'motdepasse1');
      expect(container.read(authTokenProvider), 'jwt-awa@test.local');
    });

    test('le serveur ne joint pas Firebase : connexion par l’API', () async {
      firebase.accounts['awa@test.local'] = 'motdepasse1';
      server.handler = (request) async => switch (request.path) {
        '/auth/firebase' => jsonResponse(503, {
          'error': 'Firebase momentanément indisponible',
          'details': {'code': 'firebase_unavailable'},
        }),
        '/auth/login' => jsonResponse(200, session('awa@test.local')),
        _ => jsonResponse(200, {}),
      };

      await repository().login('awa@test.local', 'motdepasse1');
      await settle();

      expect(container.read(authTokenProvider), 'jwt-awa@test.local');
    });

    test('mot de passe inconnu de MySQL : message « Firebase injoignable »', () async {
      firebase.down = true;
      server.handler = (request) async =>
          jsonResponse(401, {'error': 'Email ou mot de passe incorrect'});

      await expectLater(
        repository().login('awa@test.local', 'motdepasse1'),
        throwsA(
          isA<FirebaseAuthFailure>().having(
            (e) => e.code,
            'code',
            'network-request-failed',
          ),
        ),
      );
    });

    test('inscription : compte local, recopié dans Firebase par le serveur', () async {
      firebase.down = true;
      server.handler = (request) async => jsonResponse(201, {
        'user': {'status': 'pending'},
      });

      await repository().register(registration);

      final body = bodyOf('/auth/register');
      expect(body['email'], 'awa@test.local');
      expect(body['password'], 'motdepasse1');
      expect(body.containsKey('id_token'), isFalse);
    });

    test('inscription : le serveur ne joint pas Firebase, compte local', () async {
      server.handler = (request) async {
        final body = jsonDecode(jsonEncode(request.data)) as Map;
        return body.containsKey('id_token')
            ? jsonResponse(503, {
                'error': 'Firebase momentanément indisponible',
                'details': {'code': 'firebase_unavailable'},
              })
            : jsonResponse(201, {
                'user': {'status': 'pending'},
              });
      };

      await repository().register(registration);

      expect(bodyOf('/auth/register')['password'], 'motdepasse1');
      expect(bodyOf('/auth/register').containsKey('id_token'), isFalse);
      // Compte Firebase gardé : le serveur le rattache une fois activé.
      expect(firebase.calls, isNot(contains('delete')));
    });
  });
}
