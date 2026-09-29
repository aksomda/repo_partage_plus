import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/firebase_options.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/storage/database_opener.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Tout ce qui suit est local : l'application démarre même sans réseau.
  final store = LocalStore(await openLocalDatabase());
  final token = await store.readToken();

  // Firebase n'est utilisé que pour l'inscription et la connexion : s'il n'est
  // pas configuré, l'application démarre quand même.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (error) {
    debugPrint('Firebase indisponible : $error');
  }

  final notifications = LocalNotifications();
  try {
    await notifications.init();
  } catch (error) {
    debugPrint('Notifications locales indisponibles : $error');
  }

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
