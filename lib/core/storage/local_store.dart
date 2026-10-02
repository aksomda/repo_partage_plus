import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sembast/sembast.dart';

/// Base locale de l'appareil : session, dernière copie des données serveur
/// (« instantané ») et file des actions en attente d'envoi.
class LocalStore {
  LocalStore(this.db);

  final Database db;

  static final _session = StoreRef<String, Object?>('session');
  static final _snapshot = StoreRef<String, Object?>('snapshot');
  static final outbox = intMapStoreFactory.store('outbox');

  /// Publications et réservations faites sans compte, avec leur jeton.
  /// Propres à l'appareil : conservées à la déconnexion.
  static final _guest = StoreRef<String, Object?>('guest');

  // ---------- Session ----------

  Future<String?> readToken() async =>
      await _session.record('token').get(db) as String?;

  Future<void> saveToken(String token) =>
      _session.record('token').put(db, token);

  Future<T?> readSetting<T>(String key) async =>
      await _session.record(key).get(db) as T?;

  Future<void> saveSetting(String key, Object? value) =>
      _session.record(key).put(db, value);

  Stream<Object?> watchSetting(String key) =>
      _session.record(key).onSnapshot(db).map((record) => record?.value);

  // ---------- Instantané des données serveur ----------

  /// Enregistre chaque clé de la réponse GET /api/sync séparément.
  Future<void> saveSnapshot(Map<String, dynamic> snapshot) {
    return db.transaction((txn) async {
      for (final entry in snapshot.entries) {
        await _snapshot.record(entry.key).put(txn, entry.value);
      }
      await _session
          .record('last_sync')
          .put(txn, DateTime.now().toUtc().toIso8601String());
    });
  }

  Future<Object?> readSnapshot(String key) => _snapshot.record(key).get(db);

  Stream<Object?> watchSnapshot(String key) =>
      _snapshot.record(key).onSnapshot(db).map((record) => record?.value);

  Future<DateTime?> lastSync() async {
    final value = await readSetting<String>('last_sync');
    return value == null ? null : DateTime.parse(value);
  }

  // ---------- Invité (sans compte) ----------

  /// [kind] : `offers` ou `reservations`. Éléments les plus récents d'abord.
  Future<List<Map<String, Object?>>> readGuestItems(String kind) async {
    final value = await _guest.record(kind).get(db);
    if (value is! List) return [];
    return [
      for (final item in value)
        if (item is Map) Map<String, Object?>.from(item),
    ];
  }

  Stream<Object?> watchGuestItems(String kind) =>
      _guest.record(kind).onSnapshot(db).map((record) => record?.value);

  /// Ajoute ou remplace (même `id`) un élément.
  Future<void> saveGuestItem(String kind, Map<String, Object?> item) async {
    final items = await readGuestItems(kind);
    items.removeWhere((existing) => existing['id'] == item['id']);
    await _guest.record(kind).put(db, [item, ...items]);
  }

  // ---------- Déconnexion ----------

  /// Efface tout : session, données et actions en attente.
  Future<void> clear() {
    return db.transaction((txn) async {
      await _session.drop(txn);
      await _snapshot.drop(txn);
      await outbox.drop(txn);
    });
  }
}

/// Remplacé dans main() par la base réellement ouverte.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider doit être surchargé'),
);
