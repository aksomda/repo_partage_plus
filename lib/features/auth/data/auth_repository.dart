import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/notifications/push_messaging.dart';
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

/// L'adresse e-mail a déjà un compte : un code de réinitialisation du mot
/// de passe a été envoyé ([resetSent]) et l'utilisateur doit se connecter.
class AccountExistsException implements Exception {
  const AccountExistsException(this.email, {required this.resetSent});

  final String email;
  final bool resetSent;

  @override
  String toString() => resetSent
      ? 'Un compte existe déjà avec $email : un code pour réinitialiser '
            'le mot de passe vous a été envoyé'
      : 'Un compte existe déjà avec $email : connectez-vous';
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
  ///
  /// Si l'adresse a déjà un compte, envoie un lien de réinitialisation du
  /// mot de passe et lève [AccountExistsException].
  Future<void> register(Registration data) async {
    try {
      await _register(data);
    } on FirebaseAuthFailure catch (error) {
      if (error.code != 'email-already-in-use') rethrow;
      throw await _accountExists(data.email);
    } on ApiException catch (error) {
      if (error.code != 'email_taken') rethrow;
      throw await _accountExists(data.email);
    }
  }

  Future<AccountExistsException> _accountExists(String email) async {
    try {
      await requestPasswordReset(email);
      return AccountExistsException(email, resetSent: true);
    } catch (_) {
      // Serveur injoignable, ou code demandé il y a moins d'une minute :
      // l'utilisateur peut toujours utiliser « Mot de passe oublié ».
      return AccountExistsException(email, resetSent: false);
    }
  }

  Future<void> _register(Registration data) async {
    final String idToken;
    final bool createdNow;
    try {
      (idToken, createdNow) = await _firebaseAccount(data.email, data.password);
    } on FirebaseAuthFailure catch (error) {
      if (error.code != 'not-configured' && !error.isUnavailable) rethrow;
      await _registerLocally(data);
      return;
    }

    try {
      // Mot de passe joint : gardé haché par l'API, pour se connecter
      // quand Firebase est injoignable.
      await _post(ApiEndpoints.register, {
        'id_token': idToken,
        'password': data.password,
        ..._profile(data),
      });
    } on ApiException catch (error) {
      if (error.code != 'firebase_unavailable') {
        await _dropRefusedAccount(error, createdNow: createdNow);
        rethrow;
      }
      // Le serveur ne joint pas Firebase : compte enregistré dans MySQL,
      // rattaché au compte Firebase par le serveur une fois activé.
      await _registerLocally(data);
    } finally {
      await _firebase.signOut();
    }
  }

  /// Pas de compte Firebase orphelin si le profil a été refusé (4xx).
  /// Sans réponse (délai dépassé, réseau) ou sur 5xx, le profil a pu être
  /// enregistré : on garde le compte, une nouvelle tentative le reprendra.
  Future<void> _dropRefusedAccount(
    ApiException error, {
    required bool createdNow,
  }) async {
    final status = error.statusCode;
    if (createdNow && status != null && status >= 400 && status < 500) {
      await _firebase.deleteCurrentAccount().catchError((_) {});
    }
  }

  /// Sans Firebase (Windows/Linux non configuré, ou Firebase injoignable) :
  /// compte local, mot de passe haché dans MySQL par l'API, qui le recopie
  /// dans Firebase en arrière-plan une fois le compte activé.
  Future<void> _registerLocally(Registration data) => _post(
    ApiEndpoints.register,
    {'email': data.email, 'password': data.password, ..._profile(data)},
  );

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
        // Autre mot de passe : le serveur libère le compte s'il n'a aucun
        // profil (inscription abandonnée), puis on le recrée une fois.
        if (!await _releaseOrphan(email)) throw error;
        try {
          return (await _firebase.createAccount(email, password), true);
        } on FirebaseAuthFailure {
          throw error;
        }
      }
    }
  }

  /// Demande au serveur de libérer un compte Firebase sans profil. false si
  /// le serveur est injoignable (le compte reste alors bloqué).
  Future<bool> _releaseOrphan(String email) async {
    try {
      await _post(ApiEndpoints.releaseOrphan, {'email': email});
      return true;
    } on ApiException {
      return false;
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
      // Mot de passe joint : gardé haché par l'API (connexion de secours).
      data = await _post(ApiEndpoints.firebaseSession, {
        'id_token': idToken,
        'password': password,
      });
    } on FirebaseAuthFailure catch (error) {
      if (!error.allowsLegacyLogin) rethrow;
      // Comptes de démo, ou Firebase injoignable : connexion par l'API.
      await _passwordLogin(email, password, firebaseError: error);
      return;
    } on ApiException catch (error) {
      if (error.code == 'firebase_unavailable') {
        // Le serveur ne joint pas Firebase : connexion par MySQL.
        await _passwordLogin(email, password);
        return;
      }
      throw _pendingOr(error, email);
    } finally {
      await _firebase.signOut();
    }
    await _saveSession(data);
  }

  /// Connexion par l'API avec le mot de passe haché dans MySQL. Si Firebase
  /// était injoignable et que MySQL ne connaît pas ce mot de passe (compte
  /// jamais connecté depuis), l'erreur de Firebase est plus juste.
  Future<void> _passwordLogin(
    String email,
    String password, {
    FirebaseAuthFailure? firebaseError,
  }) async {
    try {
      await _saveSession(
        await _post(ApiEndpoints.login, {'email': email, 'password': password}),
      );
    } on ApiException catch (error) {
      if (firebaseError != null &&
          firebaseError.isUnavailable &&
          error.statusCode == 401) {
        throw firebaseError;
      }
      throw _pendingOr(error, email);
    }
  }

  Exception _pendingOr(ApiException error, String email) =>
      error.code == 'account_pending'
      ? AccountPendingException(error.details?['email'] as String? ?? email)
      : error;

  /// Envoie un code à 6 chiffres par e-mail (sans erreur si l'adresse est
  /// inconnue : on ne révèle pas quels comptes existent).
  Future<void> requestPasswordReset(String email) =>
      _post(ApiEndpoints.forgotPassword, {'email': email});

  /// Nouveau mot de passe avec le code reçu, sans aide d'un administrateur.
  Future<void> resetPassword({
    required String email,
    required String code,
    required String password,
  }) => _post(ApiEndpoints.resetPassword, {
    'email': email,
    'code': code,
    'password': password,
  });

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
        throw ApiException.unreachable();
      }
      throw ApiException.fromDio(error);
    }
  }

  Future<void> _saveSession(Map<String, dynamic> data) async {
    final store = _ref.read(localStoreProvider);
    final token = data['token'] as String;
    // Reconnexion après une session refusée : même compte, les actions en
    // attente sont gardées et partiront ; autre compte, les données et
    // actions de l'ancien sont effacées (rien n'est envoyé en son nom).
    final previous = asJson(await store.readSnapshot('profile'))?['id'];
    final user = asJson(data['user']);
    if (previous != null && previous != user?['id']) {
      // Déconnexion de l'ancien compte d'abord : favoris et préférences en
      // mémoire sont vidés, ils ne passent pas dans le nouveau compte.
      _ref.read(authTokenProvider.notifier).set(null);
      await store.clear();
    }
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
    await _ref.read(pushMessagingProvider).unregister();
    await _firebase.signOut();
    await _ref.read(localStoreProvider).clear();
    _ref.read(authTokenProvider.notifier).set(null);
  }
}

final authRepositoryProvider = Provider<AuthRepository>(AuthRepository.new);
