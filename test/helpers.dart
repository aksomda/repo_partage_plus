import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sembast/sembast_memory.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

var _databaseCount = 0;

/// Base locale en mémoire, neuve à chaque appel.
Future<LocalStore> memoryStore() async {
  _databaseCount++;
  return LocalStore(
    await databaseFactoryMemory.openDatabase('test_$_databaseCount.db'),
  );
}

/// Surcharges pour lancer l'application en test : base en mémoire et réseau
/// simulé (pas de plugin natif de connectivité).
Future<List<Override>> testOverrides({bool online = false}) async {
  final store = await memoryStore();
  return [
    localStoreProvider.overrideWithValue(store),
    onlineProvider.overrideWith((ref) => Stream.value(online)),
  ];
}

/// Faux serveur : chaque requête passe par [handler].
class FakeServer implements HttpClientAdapter {
  FakeServer(this.handler);

  Future<ResponseBody> Function(RequestOptions request) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// Faux Firebase Auth : comptes en mémoire, jeton `token-<email>`.
class FakeAuthGateway implements AuthGateway {
  final accounts = <String, String>{};
  final calls = <String>[];
  String? current;

  @override
  Future<String> createAccount(String email, String password) async {
    calls.add('create');
    if (accounts.containsKey(email)) {
      throw const FirebaseAuthFailure('email-already-in-use', 'Déjà utilisé');
    }
    accounts[email] = password;
    current = email;
    return 'token-$email';
  }

  @override
  Future<String> signIn(String email, String password) async {
    calls.add('signIn');
    if (accounts[email] != password) {
      throw const FirebaseAuthFailure('invalid-credential', 'Incorrect');
    }
    current = email;
    return 'token-$email';
  }

  @override
  Future<void> deleteCurrentAccount() async {
    calls.add('delete');
    accounts.remove(current);
  }

  @override
  Future<void> sendPasswordReset(String email) async => calls.add('reset');

  @override
  Future<void> signOut() async {
    calls.add('signOut');
    current = null;
  }
}
