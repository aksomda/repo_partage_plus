import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'package:repo_partage_plus/firebase_options.dart';

Future<void>? _initializing;

/// Initialise Firebase une seule fois. Lancé sans attendre au démarrage
/// (pour ne pas retarder le premier écran), puis attendu par les
/// fonctions qui s'en servent (connexion, IA). Sans Firebase configuré,
/// l'application fonctionne quand même.
Future<void> ensureFirebase() {
  return _initializing ??= () async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (error) {
      debugPrint('Firebase indisponible : $error');
    }
  }();
}
