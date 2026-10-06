import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/offline/sync_service.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';

Json? _adminSnapshot(Ref ref) =>
    asJson(ref.watch(snapshotProvider('admin')).value);

/// Offres visibles, que l'administrateur peut retirer en cas d'abus ;
/// sans celles déjà retirées hors ligne.
final moderationOffersProvider = Provider<List<Json>>((ref) {
  final handled = {
    for (final action in ref.watch(waitingActionsProvider))
      if (action.kind == 'offer.moderate') action.targetId,
  };
  return asJsonList(
    _adminSnapshot(ref)?['moderation_offers'],
  ).where((offer) => !handled.contains(offer['id'])).toList();
});

/// Acteurs configurés, y compris ceux modifiés hors ligne pas encore envoyés.
final actorsProvider = Provider<List<Json>>(
  (ref) => asJsonList(_adminSnapshot(ref)?['actors']),
);

/// Paramètres de la plateforme (quotas sans compte), modifications hors ligne
/// pas encore envoyées comprises.
final adminSettingsProvider = Provider<Json>((ref) {
  return {
    ...?asJson(_adminSnapshot(ref)?['settings']),
    for (final action in ref.watch(waitingActionsProvider))
      if (action.kind == 'settings.save' && !action.isRejected) ...?action.body,
  };
});

/// Comptes utilisateurs, lus dans la copie locale (instantané `admin.users`,
/// recopié à chaque synchronisation) : l'écran reste utilisable hors ligne et
/// si MySQL est en panne. Modifications pas encore envoyées comprises :
/// statut demandé (`pending_status`) et comptes ajoutés (`pending_create`).
final adminUsersProvider = Provider<List<Json>>((ref) {
  final actions = ref.watch(waitingActionsProvider);
  final statuses = {
    for (final action in actions)
      if (action.kind == 'user.status' && action.targetId != null)
        action.targetId!: action.body!['status']! as String,
  };
  return [
    for (final action in actions.reversed)
      if (action.kind == 'user.create') _pendingUser(action),
    for (final user in asJsonList(_adminSnapshot(ref)?['users']))
      {...user, 'pending_status': ?statuses[user['id']]},
  ];
});

/// Compte ajouté hors ligne, affiché en attendant sa création sur le serveur.
Json _pendingUser(PendingAction action) {
  final body = action.body!;
  return {
    'id': null,
    'local_id': action.localId,
    'name': '${body['first_name']} ${body['last_name']}',
    'email': body['email'],
    'phone': body['phone'],
    'actor_label': body['actor_label'],
    'role': body['role'],
    'status': 'active',
    'pending_create': true,
    'created_at': action.createdAt.toIso8601String(),
  };
}

/// Origine de la copie locale des comptes : `mysql` (synchronisation
/// normale) ou `firestore` (copie de secours, MySQL indisponible).
final adminUsersSourceProvider = Provider<String>(
  (ref) => _adminSnapshot(ref)?['users_source'] as String? ?? 'mysql',
);

/// Statut affiché : celui demandé hors ligne s'il y en a un.
String effectiveStatus(Json user) =>
    (user['pending_status'] ?? user['status']) as String? ?? 'active';

/// Filtre de recherche (nom, e-mail, rôle), sans tenir compte des accents
/// ni de la casse.
List<Json> searchUsers(List<Json> users, String query) => [
  for (final user in users)
    if (matchesSearch(
      '${user['name'] ?? ''} ${user['email'] ?? ''} ${user['actor_label'] ?? ''}',
      query,
    ))
      user,
];

/// Résultat d'une actualisation de la liste des comptes.
enum UsersRefresh {
  /// Synchronisation complète réussie (MySQL).
  mysql,

  /// MySQL indisponible : copie Firestore relue par le serveur.
  firestore,

  /// Serveur injoignable : on garde la copie locale.
  offline,
}

/// Réservations de toute la plateforme (copie locale, sans code de retrait).
final adminReservationsProvider = Provider<List<Json>>(
  (ref) => asJsonList(_adminSnapshot(ref)?['reservations']),
);

/// Impact global de la plateforme : `impact`, `monthly`, `by_category`.
final adminImpactProvider = Provider<Json?>(
  (ref) => asJson(_adminSnapshot(ref)?['impact_global']),
);

/// Compteurs (associations en attente, acteurs, catégories…).
final adminStatsProvider = Provider<Json>(
  (ref) => asJson(_adminSnapshot(ref)?['stats']) ?? const {},
);

final factorsProvider = Provider<List<Json>>(
  (ref) => asJsonList(_adminSnapshot(ref)?['factors']),
);

/// Toutes les décisions d'administration passent par la file :
/// un admin peut modérer hors ligne, l'envoi se fait au retour du réseau.
class AdminRepository {
  AdminRepository(this._sync, this._dio, this._store);

  final SyncController _sync;
  final Dio _dio;
  final LocalStore _store;

  /// Actualise la copie locale des comptes : synchronisation complète (file
  /// d'attente envoyée, puis instantané MySQL) ; en cas d'échec, liste relue
  /// par l'API dans la copie Firestore. Ne lève jamais d'exception : hors
  /// ligne, la copie locale reste affichée.
  Future<UsersRefresh> refreshUsers() async {
    final report = await _sync.syncNow();
    if (report.outcome == SyncOutcome.done) return UsersRefresh.mysql;
    if (report.outcome != SyncOutcome.offline) return UsersRefresh.offline;

    try {
      const page = 100;
      final users = <Object?>[];
      var source = 'mysql';
      // Même plafond que l'instantané (/sync).
      while (users.length < 2000) {
        final response = await _dio.get<List<dynamic>>(
          ApiEndpoints.adminUsers,
          queryParameters: {'limit': page, 'offset': users.length},
        );
        source = response.headers.value('x-data-source') ?? source;
        final rows = response.data ?? const [];
        users.addAll(rows);
        if (rows.length < page) break;
      }
      await _store.patchSnapshot('admin', {
        'users': users,
        'users_source': source,
      });
      return source == 'firestore'
          ? UsersRefresh.firestore
          : UsersRefresh.mysql;
    } on DioException {
      return UsersRefresh.offline;
    }
  }

  /// Ajoute un compte (actif d'emblée, mot de passe provisoire). Hors ligne :
  /// mis en file et affiché « en attente d'envoi » ; créé au retour du réseau.
  Future<SubmitResult> createUser({
    required String firstName,
    required String lastName,
    required String email,
    String? phone,
    required Json actor,
    required String password,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'user.create',
        method: 'POST',
        path: ApiEndpoints.adminUsers,
        body: {
          'first_name': firstName,
          'last_name': lastName,
          'email': email,
          'phone': phone,
          'actor_id': actor['id'],
          'password': password,
          // Affichage local seulement (ignorés par le serveur).
          'actor_label': actor['label'],
          'role': actor['permission_role'],
        },
        label: 'Ajout du compte de $firstName $lastName',
      ),
    );
  }

  /// Retire une offre abusive (publiée avec ou sans compte) : réservations
  /// annulées, publieur notifié, et prévenu par e-mail s'il en a laissé un.
  Future<SubmitResult> withdrawOffer(Json offer, {required String reason}) {
    return _sync.submit(
      PendingAction(
        kind: 'offer.moderate',
        method: 'PATCH',
        path: ApiEndpoints.moderateOffer(offer['id'] as int),
        body: {'decision': 'reject', 'reason': reason},
        targetId: offer['id'] as int,
        label: 'Retrait de « ${offer['title']} »',
      ),
    );
  }

  Future<SubmitResult> setUserStatus(
    int userId, {
    required bool suspended,
    String? reason,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'user.status',
        method: 'PATCH',
        path: ApiEndpoints.userStatus(userId),
        body: {'status': suspended ? 'suspended' : 'active', 'reason': ?reason},
        targetId: userId,
        label: suspended ? 'Désactivation du compte' : 'Réactivation du compte',
      ),
    );
  }

  /// Crée ([id] null) ou modifie un acteur.
  Future<SubmitResult> saveActor({
    int? id,
    required String code,
    required String label,
    String? description,
    String? icon,
    required String permissionRole,
    required bool selfSignup,
    required bool active,
    int sortOrder = 0,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'actor.save',
        method: id == null ? 'POST' : 'PUT',
        path: id == null
            ? ApiEndpoints.adminActors
            : ApiEndpoints.adminActor(id),
        body: {
          'code': code,
          'label': label,
          'description': description,
          'icon': icon,
          'permission_role': permissionRole,
          'self_signup': selfSignup,
          'active': active,
          'sort_order': sortOrder,
        },
        targetId: id,
        label: 'Acteur « $label »',
      ),
    );
  }

  Future<SubmitResult> deleteActor(int id, String label) {
    return _sync.submit(
      PendingAction(
        kind: 'actor.delete',
        method: 'DELETE',
        path: ApiEndpoints.adminActor(id),
        targetId: id,
        label: 'Suppression de l’acteur « $label »',
      ),
    );
  }

  Future<SubmitResult> saveCategory({
    int? id,
    required String name,
    String? icon,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'category.save',
        method: id == null ? 'POST' : 'PUT',
        path: id == null
            ? ApiEndpoints.adminCategories
            : ApiEndpoints.adminCategory(id),
        body: {'name': name, 'icon': icon},
        targetId: id,
        label: 'Catégorie « $name »',
      ),
    );
  }

  Future<SubmitResult> deleteCategory(int id, String name) {
    return _sync.submit(
      PendingAction(
        kind: 'category.delete',
        method: 'DELETE',
        path: ApiEndpoints.adminCategory(id),
        targetId: id,
        label: 'Suppression de « $name »',
      ),
    );
  }

  Future<SubmitResult> saveFactor({
    int? id,
    required int categoryId,
    required double co2KgPerKg,
    double mealsPerKg = 2.5,
    String? source,
  }) {
    return _sync.submit(
      PendingAction(
        kind: 'factor.save',
        method: id == null ? 'POST' : 'PUT',
        path: id == null
            ? ApiEndpoints.adminFactors
            : ApiEndpoints.adminFactor(id),
        body: {
          'category_id': categoryId,
          'co2_kg_per_kg': co2KgPerKg,
          'meals_per_kg': mealsPerKg,
          'source': source,
        },
        targetId: id,
        label: 'Facteur d’impact',
      ),
    );
  }

  /// [settings] : clés de GET /api/admin/settings, valeurs entières.
  Future<SubmitResult> saveSettings(Map<String, int> settings) {
    return _sync.submit(
      PendingAction(
        kind: 'settings.save',
        method: 'PUT',
        path: ApiEndpoints.adminSettings,
        body: settings,
        label: 'Paramètres',
      ),
    );
  }

  Future<SubmitResult> deleteFactor(int id) {
    return _sync.submit(
      PendingAction(
        kind: 'factor.delete',
        method: 'DELETE',
        path: ApiEndpoints.adminFactor(id),
        targetId: id,
        label: 'Suppression d’un facteur',
      ),
    );
  }
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(
    ref.read(syncControllerProvider.notifier),
    ref.read(dioProvider),
    ref.read(localStoreProvider),
  ),
);
