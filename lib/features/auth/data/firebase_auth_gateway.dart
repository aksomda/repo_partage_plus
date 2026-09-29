import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final authGatewayProvider = Provider<AuthGateway>(
  (ref) => FirebaseAuthGateway(),
);
