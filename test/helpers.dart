import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sembast/sembast_memory.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

var _databaseCount = 0;

/// Base locale en mémoire, neuve à chaque appel.
Future<LocalStore> memoryStore() async {
  _databaseCount++;
  return LocalStore(
    await databaseFactoryMemory.openDatabase('test_$_databaseCount.db'),
  );
}

/// Surcharges pour lancer l'application en test : base en mémoire et réseau
/// simulé (pas de plugin natif de connectivité).
Future<List<Override>> testOverrides({bool online = false}) async {
  final store = await memoryStore();
  return [
    localStoreProvider.overrideWithValue(store),
    onlineProvider.overrideWith((ref) => Stream.value(online)),
  ];
}
