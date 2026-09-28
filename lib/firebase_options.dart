// Fichier provisoire : à remplacer par celui généré avec
//   dart pub global activate flutterfire_cli
//   flutterfire configure --project=<id-du-projet-firebase>
// (voir docs/FIREBASE.md). Tant qu'il n'est pas généré, l'application démarre
// mais l'inscription et la connexion Firebase sont indisponibles ; seuls les
// comptes de démo (connexion par mot de passe de l'API) fonctionnent.

import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => throw UnsupportedError(
    'Firebase non configuré : lancer « flutterfire configure »',
  );
}
