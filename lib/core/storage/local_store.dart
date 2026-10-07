import 'dart:convert';
import 'dart:typed_data';

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

  /// Images téléchargées (pièces jointes du mini chat), en base64 : affichées
  /// hors ligne. Privées : effacées à la déconnexion.
  static final _images = StoreRef<String, String>('images');

  // ---------- Session ----------

  Future<String?> readToken() async =>
      await _session.record('token').get(db) as String?;

  Future<void> saveToken(String token) =>
      _session.record('token').put(db, token);

  Future<T?> readSetting<T>(String key) async =>
      await _session.record(key).get(db) as T?;

  /// [value] null efface le réglage (sembast refuse les valeurs null).
  Future<void> saveSetting(String key, Object? value) async {
    final record = _session.record(key);
    value == null ? await record.delete(db) : await record.put(db, value);
  }

  Stream<Object?> watchSetting(String key) =>
      _session.record(key).onSnapshot(db).map((record) => record?.value);

  // ---------- Instantané des données serveur ----------

  /// Enregistre chaque clé de la réponse GET /api/sync séparément.
  /// Une clé à null (ex. `admin` pour un non-admin) efface la copie locale :
  /// sembast refuse d'enregistrer null.
  ///
  /// Seules les clés modifiées sont réécrites : les écrans qui les observent
  /// ne se reconstruisent pas pour rien, et le fichier de la base (relu en
  /// entier au démarrage) ne grossit pas à chaque synchronisation.
  Future<void> saveSnapshot(Map<String, dynamic> snapshot) {
    return db.transaction((txn) async {
      for (final entry in snapshot.entries) {
        final record = _snapshot.record(entry.key);
        final current = await record.get(txn);
        if (current == null && entry.value == null) continue;
        if (current != null &&
            entry.value != null &&
            jsonEncode(current) == jsonEncode(entry.value)) {
          continue;
        }
        // Correction erreur lors de la publication d'une offre
        if (entry.value != null) {
          await record.put(txn, entry.value);
        } else {
          await record.delete(txn);
        }
      }
      await _session
          .record('last_sync')
          .put(txn, DateTime.now().toUtc().toIso8601String());
    });
  }

  Future<Object?> readSnapshot(String key) => _snapshot.record(key).get(db);

  /// Remplace quelques champs d'une clé de l'instantané (ex. `admin.users`
  /// relus seuls), sans toucher aux autres ni à la date de synchronisation.
  Future<void> patchSnapshot(String key, Map<String, Object?> fields) {
    return db.transaction((txn) async {
      final record = _snapshot.record(key);
      final current = await record.get(txn);
      await record.put(txn, {
        if (current is Map) ...current.cast<String, Object?>(),
        ...fields,
      });
    });
  }

  Stream<Object?> watchSnapshot(String key) =>
      _snapshot.record(key).onSnapshot(db).map((record) => record?.value);

  Future<DateTime?> lastSync() async {
    final value = await readSetting<String>('last_sync');
    return value == null ? null : DateTime.parse(value);
  }

  // ---------- Images en cache ----------

  Future<Uint8List?> readImage(String key) async {
    final value = await _images.record(key).get(db);
    return value == null ? null : base64Decode(value);
  }

  Future<void> saveImage(String key, Uint8List bytes) =>
      _images.record(key).put(db, base64Encode(bytes));

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

  /// Modifie quelques champs d'un élément, sans changer sa place.
  Future<void> patchGuestItem(
    String kind,
    Object? id,
    Map<String, Object?> fields,
  ) async {
    final items = await readGuestItems(kind);
    await _guest.record(kind).put(db, [
      for (final item in items) item['id'] == id ? {...item, ...fields} : item,
    ]);
  }

  // ---------- Déconnexion ----------

  /// Efface tout : session, données et actions en attente.
  Future<void> clear() {
    return db.transaction((txn) async {
      await _session.drop(txn);
      await _snapshot.drop(txn);
      await outbox.drop(txn);
      await _images.drop(txn);
    });
  }
}

/// Remplacé dans main() par la base réellement ouverte.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider doit être surchargé'),
);
