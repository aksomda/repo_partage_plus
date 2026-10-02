import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

typedef Json = Map<String, dynamic>;

/// Une clé de l'instantané local (profile, offers, reservations…),
/// mise à jour automatiquement après chaque synchronisation.
final snapshotProvider = StreamProvider.family<Object?, String>(
  (ref, key) => ref.watch(localStoreProvider).watchSnapshot(key),
);

/// Liste JSON de l'instantané local (vide si jamais synchronisée).
final snapshotListProvider = Provider.family<List<Json>, String>((ref, key) {
  final value = ref.watch(snapshotProvider(key)).value;
  return asJsonList(value);
});

/// Toutes les actions de la file (en attente et refusées).
final pendingActionsProvider = StreamProvider<List<PendingAction>>(
  (ref) => ref.watch(outboxProvider).watchAll(),
);

/// Actions pas encore envoyées, pour les badges « en attente d'envoi ».
final waitingActionsProvider = Provider<List<PendingAction>>((ref) {
  final actions = ref.watch(pendingActionsProvider).value ?? const [];
  return actions.where((action) => !action.isRejected).toList();
});

List<Json> asJsonList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}

Json? asJson(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

/// Ajoute à chaque élément la liste des actions locales qui le concernent,
/// sous `pending_actions` (ex. `['reservation.confirm']`).
List<Json> withPendingActions(
  List<Json> items,
  List<PendingAction> actions,
  String kindPrefix,
) {
  return [
    for (final item in items)
      {
        ...item,
        'pending_actions': [
          for (final action in actions)
            if (action.kind.startsWith(kindPrefix) &&
                action.targetId == item['id'])
              action.kind,
        ],
      },
  ];
}
