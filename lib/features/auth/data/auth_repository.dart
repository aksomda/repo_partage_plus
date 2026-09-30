import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/firebase_auth_gateway.dart';

/// Profil de l'utilisateur connecté (lu localement, disponible hors ligne).
final profileProvider = Provider<Json?>(
  (ref) => asJson(ref.watch(snapshotProvider('profile')).value),
);

final isLoggedInProvider = Provider<bool>(
  (ref) => ref.watch(authTokenProvider) != null,
);

/// Acteurs proposés à l'inscription (particulier, commerçant…), lus sur l'API.
final signupActorsProvider = FutureProvider.autoDispose<List<Json>>((
  ref,
) async {
  try {
    final response = await ref
        .read(dioProvider)
        .get<List<dynamic>>(ApiEndpoints.actors);
    return asJsonList(response.data);
  } on DioException catch (error) {
    throw ApiException.fromDio(error);
  }
});

/// Données saisies à l'inscription.
class Registration {
  const Registration({
    required this.actorId,
    required this.lastName,
    required this.firstName,
    required this.gender,
    required this.age,
    required this.email,
    required this.phone,
    required this.password,
    this.association,
  });

  final int actorId;
  final String lastName;
  final String firstName;

  /// `male` ou `female`.
  final String gender;
  final int age;
  final String email;
  final String phone;
  final String password;

  /// Pour un acteur de type association : name, registration_number, address.
  final Map<String, String>? association;
}

/// La connexion a réussi côté Firebase mais le compte attend son code
/// d'activation : l'écran de saisie du code doit être affiché.
class AccountPendingException implements Exception {
  const AccountPendingException(this.email);

  final String email;

  @override
  String toString() => 'Compte non activé : saisissez le code reçu par e-mail';
}

/// Le mot de passe est géré par Firebase Auth, le profil par l'API (MySQL).
/// L'API renvoie ensuite son propre jeton, utilisé pour toutes les requêtes.
///
/// La première connexion exige le réseau ; ensuite la session est gardée
/// sur l'appareil et l'application s'ouvre même hors ligne.
class AuthRepository {
  AuthRepository(this._ref);

  final Ref _ref;

  AuthGateway get _firebase => _ref.read(authGatewayProvider);

  /// Crée le compte Firebase puis le profil. Le compte reste inactif jusqu'à
  /// la saisie du code envoyé par e-mail ([verifyEmail]).
  Future<void> register(Registration data) async {
    final String idToken;
    final bool createdNow;
    try {
      (idToken, createdNow) = await _firebaseAccount(data.email, data.password);
    } on FirebaseAuthFailure catch (error) {
      if (error.code != 'not-configured') rethrow;
      // Sans Firebase (ex. Windows/Linux non configuré) : compte local,
      // mot de passe haché et enregistré dans MySQL par l'API.
      await _post(ApiEndpoints.register, {
        'email': data.email,
        'password': data.password,
        ..._profile(data),
      });
      return;
    }

    try {
      await _post(ApiEndpoints.register, {
        'id_token': idToken,
        ..._profile(data),
      });
    } catch (_) {
      // Pas de compte Firebase orphelin si le profil n'a pas été enregistré.
      if (createdNow) {
        await _firebase.deleteCurrentAccount().catchError((_) {});
      }
      rethrow;
    } finally {
      await _firebase.signOut();
    }
  }

  Map<String, Object?> _profile(Registration data) => {
    'actor_id': data.actorId,
    'last_name': data.lastName,
    'first_name': data.firstName,
    'gender': data.gender,
    'age': data.age,
    'phone': data.phone,
    'association': ?data.association,
  };

  /// Jeton du compte Firebase, et true s'il vient d'être créé.
  Future<(String, bool)> _firebaseAccount(String email, String password) async {
    try {
      return (await _firebase.createAccount(email, password), true);
    } on FirebaseAuthFailure catch (error) {
      if (error.code != 'email-already-in-use') rethrow;
      // Inscription précédente interrompue (profil jamais enregistré) :
      // on reprend le compte Firebase existant si le mot de passe correspond.
      try {
        return (await _firebase.signIn(email, password), false);
      } on FirebaseAuthFailure {
        throw error;
      }
    }
  }

  /// Active le compte avec le code à 6 chiffres, puis ouvre la session.
  Future<void> verifyEmail(String email, String code) async {
    final data = await _post(ApiEndpoints.verifyEmail, {
      'email': email,
      'code': code,
    });
    await _saveSession(data);
  }

  Future<void> resendCode(String email) =>
      _post(ApiEndpoints.resendCode, {'email': email});

  /// Connexion avec l'adresse e-mail et le mot de passe de l'inscription.
  ///
  /// Lève [AccountPendingException] si le compte n'est pas encore activé.
  Future<void> login(String email, String password) async {
    final Map<String, dynamic> data;
    try {
      final idToken = await _firebase.signIn(email, password);
      data = await _post(ApiEndpoints.firebaseSession, {'id_token': idToken});
    } on FirebaseAuthFailure catch (error) {
      if (!error.allowsLegacyLogin) rethrow;
      // Comptes de démo créés sans Firebase : connexion directe par l'API.
      await _saveSession(
        await _post(ApiEndpoints.login, {'email': email, 'password': password}),
      );
      return;
    } on ApiException catch (error) {
      if (error.code == 'account_pending') {
        throw AccountPendingException(
          error.details?['email'] as String? ?? email,
        );
      }
      rethrow;
    } finally {
      await _firebase.signOut();
    }
    await _saveSession(data);
  }

  Future<void> sendPasswordReset(String email) =>
      _firebase.sendPasswordReset(email);

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    try {
      final response = await _ref
          .read(dioProvider)
          .post<Map<String, dynamic>>(path, data: body);
      return response.data ?? const {};
    } on DioException catch (error) {
      if (error.response == null) {
        throw ApiException('Connexion Internet requise');
      }
      throw ApiException.fromDio(error);
    }
  }

  Future<void> _saveSession(Map<String, dynamic> data) async {
    final store = _ref.read(localStoreProvider);
    final token = data['token'] as String;
    await store.saveToken(token);
    await store.saveSnapshot({'profile': data['user']});
    _ref.read(authTokenProvider.notifier).set(token);

    // Copie locale complète en arrière-plan.
    _ref.read(syncControllerProvider.notifier).syncNow();
  }

  /// Actions encore en attente : les perdre si l'utilisateur se déconnecte.
  int get unsentActions => _ref.read(waitingActionsProvider).length;

  /// Efface la session et toutes les données locales.
  /// Vérifier [unsentActions] avant, et prévenir l'utilisateur.
  Future<void> logout() async {
    await _firebase.signOut();
    await _ref.read(localStoreProvider).clear();
    _ref.read(authTokenProvider.notifier).set(null);
  }
}

final authRepositoryProvider = Provider<AuthRepository>(AuthRepository.new);
