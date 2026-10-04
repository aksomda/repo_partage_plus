import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/core/firebase/firebase_init.dart';
import 'package:repo_partage_plus/core/maps/offline_tiles.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/storage/database_opener.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/core/widgets/friendly_error.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _keepRunningOnErrors();

  // Seul le strict nécessaire au premier écran est attendu (base locale,
  // session) : l'application démarre vite, même sans réseau. Le cache de
  // cartes est facultatif : son échec n'empêche pas de démarrer.
  final (database, _) = await (
    openLocalDatabase(),
    initMapCache().catchError((Object error) {
      debugPrint('Cache de cartes indisponible : $error');
    }),
  ).wait;
  final store = LocalStore(database);
  final token = await store.readToken();

  // Firebase (connexion, IA) et notifications (demande d'autorisation)
  // s'initialisent pendant que le premier écran s'affiche.
  unawaited(ensureFirebase());
  final notifications = LocalNotifications();
  unawaited(
    notifications.init().catchError((Object error) {
      debugPrint('Notifications locales indisponibles : $error');
    }),
  );

  runApp(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        initialTokenProvider.overrideWithValue(token),
        localNotificationsProvider.overrideWithValue(notifications),
      ],
      child: const RepasPartageApp(),
    ),
  );
}

/// Une erreur imprévue (réseau, Firebase, serveur…) est journalisée sans
/// fermer l'application ; un widget en erreur affiche un message convivial
/// au lieu de l'écran rouge.
void _keepRunningOnErrors() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('Erreur d’affichage : ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Erreur non gérée (l’application continue) : $error');
    return true;
  };
  ErrorWidget.builder = (details) => FriendlyErrorWidget(details: details);
}
