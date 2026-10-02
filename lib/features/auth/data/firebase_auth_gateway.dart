import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/firebase/firebase_rest.dart';

/// Erreur d'authentification Firebase, avec un message lisible.
class FirebaseAuthFailure implements Exception {
  const FirebaseAuthFailure(this.code, this.message);

  /// Code Firebase (`invalid-credential`, `email-already-in-use`…) ou
  /// `not-configured` si Firebase n'est pas initialisé.
  final String code;
  final String message;

  /// Identifiants refusés ou Firebase absent : on peut tenter l'ancienne
  /// connexion de l'API (comptes de démo).
  bool get allowsLegacyLogin => const {
    'not-configured',
    'invalid-credential',
    'user-not-found',
    'wrong-password',
  }.contains(code);

  @override
  String toString() => message;
}

/// Accès à Firebase Auth : création de compte, connexion, mot de passe.
/// Chaque méthode qui connecte renvoie le jeton d'identité à envoyer à l'API.
abstract class AuthGateway {
  Future<String> createAccount(String email, String password);
  Future<String> signIn(String email, String password);
  Future<void> deleteCurrentAccount();
  Future<void> sendPasswordReset(String email);
  Future<void> signOut();
}

class FirebaseAuthGateway implements AuthGateway {
  FirebaseAuth get _auth {
    if (Firebase.apps.isEmpty) {
      throw const FirebaseAuthFailure(
        'not-configured',
        'Firebase n’est pas configuré dans cette version de l’application',
      );
    }
    return FirebaseAuth.instance;
  }

  @override
  Future<String> createAccount(String email, String password) => _run(() async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    return (await credential.user!.getIdToken())!;
  });

  @override
  Future<String> signIn(String email, String password) => _run(() async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    return (await credential.user!.getIdToken())!;
  });

  @override
  Future<void> deleteCurrentAccount() =>
      _run(() async => _auth.currentUser?.delete());

  @override
  Future<void> sendPasswordReset(String email) =>
      _run(() => _auth.sendPasswordResetEmail(email: email));

  @override
  Future<void> signOut() async {
    if (Firebase.apps.isNotEmpty) await FirebaseAuth.instance.signOut();
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseAuthException catch (error) {
      throw FirebaseAuthFailure(error.code, _message(error.code));
    }
  }

  static String _message(String code) => switch (code) {
    'email-already-in-use' => 'Un compte existe déjà avec cette adresse e-mail',
    'invalid-email' => 'Adresse e-mail invalide',
    'weak-password' => 'Mot de passe trop faible (8 caractères minimum)',
    'user-not-found' ||
    'wrong-password' ||
    'invalid-credential' => 'Email ou mot de passe incorrect',
    'user-disabled' => 'Compte désactivé par l’administrateur',
    'too-many-requests' =>
      'Trop de tentatives : réessayez dans quelques minutes',
    'network-request-failed' => 'Connexion Internet requise',
    _ => 'Erreur d’authentification ($code)',
  };
}

/// Firebase Auth par ses API HTTP officielles (Identity Toolkit), pour
/// Windows / Linux / macOS où le paquet firebase_auth n'est pas utilisable
/// en production. Même comportement que [FirebaseAuthGateway].
class RestAuthGateway implements AuthGateway {
  RestAuthGateway(this._dio, this._config);

  final Dio _dio;
  final FirebaseRestConfig? _config;

  /// Jeton de la dernière connexion (pour supprimer le compte si besoin).
  String? _idToken;

  static const _base = 'https://identitytoolkit.googleapis.com/v1/accounts';

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, Object?> body,
  ) async {
    final config = _config;
    if (config == null) {
      throw const FirebaseAuthFailure(
        'not-configured',
        'Firebase n’est pas configuré dans cette version de l’application',
      );
    }
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$_base:$action',
        queryParameters: {'key': config.apiKey},
        data: body,
      );
      return response.data ?? const {};
    } on DioException catch (error) {
      if (error.response == null) {
        throw const FirebaseAuthFailure(
          'network-request-failed',
          'Connexion Internet requise',
        );
      }
      final code = _codes[googleErrorCode(error)] ?? 'unknown';
      throw FirebaseAuthFailure(code, FirebaseAuthGateway._message(code));
    }
  }

  /// Codes de l'API HTTP → codes du SDK Firebase utilisés par l'application.
  static const _codes = {
    'EMAIL_EXISTS': 'email-already-in-use',
    'INVALID_EMAIL': 'invalid-email',
    'WEAK_PASSWORD': 'weak-password',
    'EMAIL_NOT_FOUND': 'user-not-found',
    'INVALID_PASSWORD': 'wrong-password',
    'INVALID_LOGIN_CREDENTIALS': 'invalid-credential',
    'USER_DISABLED': 'user-disabled',
    'TOO_MANY_ATTEMPTS_TRY_LATER': 'too-many-requests',
    // Connexion par e-mail non activée, clé invalide… : comme sans Firebase.
    'OPERATION_NOT_ALLOWED': 'not-configured',
    'CONFIGURATION_NOT_FOUND': 'not-configured',
    'API': 'not-configured',
  };

  Future<String> _session(String action, String email, String password) async {
    final data = await _call(action, {
      'email': email,
      'password': password,
      'returnSecureToken': true,
    });
    return _idToken = data['idToken'] as String;
  }

  @override
  Future<String> createAccount(String email, String password) =>
      _session('signUp', email, password);

  @override
  Future<String> signIn(String email, String password) =>
      _session('signInWithPassword', email, password);

  @override
  Future<void> deleteCurrentAccount() async {
    final token = _idToken;
    if (token != null) await _call('delete', {'idToken': token});
    _idToken = null;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    await _call('sendOobCode', {
      'requestType': 'PASSWORD_RESET',
      'email': email,
    });
  }

  @override
  Future<void> signOut() async => _idToken = null;
}

/// SDK Firebase sur Android, iOS et web ; API HTTP sur ordinateur.
final authGatewayProvider = Provider<AuthGateway>(
  (ref) => isDesktop
      ? RestAuthGateway(
          ref.watch(googleDioProvider),
          ref.watch(firebaseRestConfigProvider),
        )
      : FirebaseAuthGateway(),
);
