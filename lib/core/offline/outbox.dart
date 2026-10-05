import 'package:sembast/sembast.dart';

import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

/// File des actions en attente, envoyées dans l'ordre de création.
class Outbox {
  Outbox(this._db);

  final Database _db;
  final _store = LocalStore.outbox;
  final _byCreation = Finder(sortOrders: [SortOrder(Field.key)]);

  Future<PendingAction> add(PendingAction action) async {
    final id = await _store.add(_db, action.toMap());
    return action.copyWith(localId: id);
  }

  Future<List<PendingAction>> all() async {
    final records = await _store.find(_db, finder: _byCreation);
    return records.map((r) => PendingAction.fromMap(r.key, r.value)).toList();
  }

  Stream<List<PendingAction>> watchAll() {
    return _store
        .query(finder: _byCreation)
        .onSnapshots(_db)
        .map(
          (records) => records
              .map((r) => PendingAction.fromMap(r.key, r.value))
              .toList(),
        );
  }

  Future<PendingAction?> get(int localId) async {
    final value = await _store.record(localId).get(_db);
    return value == null ? null : PendingAction.fromMap(localId, value);
  }

  Future<void> update(PendingAction action) =>
      _store.record(action.localId!).put(_db, action.toMap());

  Future<void> remove(int localId) => _store.record(localId).delete(_db);

  /// Supprime les actions refusées (après que l'utilisateur les a vues).
  Future<void> clearRejected() async {
    await _store.delete(_db, finder: Finder(filter: Filter.notNull('error')));
  }
}
