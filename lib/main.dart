import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/app.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/storage/database_opener.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Tout ce qui suit est local : l'application démarre même sans réseau.
  final store = LocalStore(await openLocalDatabase());
  final token = await store.readToken();

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
