import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sembast/sembast_memory.dart';

import 'package:repo_partage_plus/core/location/location.dart';
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
Future<List<Override>> testOverrides({
  bool online = false,
  LocationGateway? location,
  LocalStore? store,
}) async {
  final localStore = store ?? await memoryStore();
  return [
    localStoreProvider.overrideWithValue(localStore),
    onlineProvider.overrideWith((ref) => Stream.value(online)),
    locationGatewayProvider.overrideWithValue(location ?? FakeLocation()),
  ];
}

/// Faux GPS : position fixe, ou refus si [failure] est donné.
class FakeLocation implements LocationGateway {
  FakeLocation({this.lat = 12.3714, this.lng = -1.5197, this.failure});

  final double lat;
  final double lng;
  final LocationFailure? failure;
  var requests = 0;

  @override
  Future<Place> currentPosition() async {
    requests++;
    if (failure != null) throw failure!;
    return Place(lat: lat, lng: lng, label: 'Ma position', isCurrent: true);
  }

  @override
  Future<void> openSettings() async {}
}

/// Offre publiée et disponible, telle que renvoyée par l'API.
Map<String, dynamic> publishedOffer({
  required int id,
  String title = 'Panier de légumes',
  double lat = 12.3714,
  double lng = -1.5197,
  num price = 0,
  int categoryId = 1,
}) {
  final now = DateTime.now();
  return {
    'id': id,
    'title': title,
    'status': 'published',
    'category_id': categoryId,
    'category_name': 'Fruits et légumes',
    'category_icon': 'eco',
    'donor_id': 2,
    'donor_name': 'Marché du Centre',
    'quantity_available': 5,
    'unit': 'panier',
    'weight_kg': 3,
    'price': price,
    'payment_info': price > 0 ? 'Orange Money 70 00 00 00' : null,
    'latitude': lat,
    'longitude': lng,
    'address': 'Marché central',
    'pickup_start': now.toUtc().toIso8601String(),
    'pickup_end': now.add(const Duration(hours: 5)).toUtc().toIso8601String(),
    'expiry_date': now
        .add(const Duration(days: 1))
        .toIso8601String()
        .substring(0, 10),
  };
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

  /// Firebase injoignable (réseau, panne).
  bool down = false;

  void _failIfDown() {
    if (down) {
      throw const FirebaseAuthFailure('network-request-failed', 'Injoignable');
    }
  }

  @override
  Future<String> createAccount(String email, String password) async {
    calls.add('create');
    _failIfDown();
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
    _failIfDown();
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

/// Réseau coupé : toute requête échoue sans réponse.
Future<ResponseBody> networkDown(RequestOptions request) => throw DioException(
  requestOptions: request,
  type: DioExceptionType.connectionError,
);
