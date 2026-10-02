import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/core/firebase/firebase_init.dart';
import 'package:repo_partage_plus/core/maps/offline_tiles.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/storage/database_opener.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Seul le strict nécessaire au premier écran est attendu (base locale,
  // session) : l'application démarre vite, même sans réseau.
  final (database, _) = await (openLocalDatabase(), initMapCache()).wait;
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
