import 'package:dio/dio.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

enum SyncOutcome {
  /// Actions envoyées et données à jour.
  done,

  /// Serveur injoignable : on réessaiera plus tard.
  offline,

  /// Session expirée : il faut se reconnecter (les actions sont conservées).
  unauthorized,

  /// Pas de session : rien à synchroniser.
  loggedOut,
}

class SyncReport {
  const SyncReport(this.outcome, {this.sent = 0, this.rejected = const []});

  final SyncOutcome outcome;
  final int sent;
  final List<PendingAction> rejected;
}

/// Envoie la file d'attente puis récupère un instantané complet (GET /sync).
class SyncService {
  SyncService({
    required this.dio,
    required this.store,
    required this.outbox,
    required this.notifications,
  });

  final Dio dio;
  final LocalStore store;
  final Outbox outbox;
  final LocalNotifications notifications;

  Future<SyncReport> sync() async {
    if (await store.readToken() == null) {
      // Visiteur sans compte : catalogue public seulement (offres, catégories),
      // pour chercher et consulter les offres même hors ligne ensuite.
      try {
        final response = await dio.get<Map<String, dynamic>>(
          ApiEndpoints.publicSync,
        );
        await store.saveSnapshot(response.data!);
      } on DioException {
        // Hors ligne : on garde la dernière copie.
      }
      return const SyncReport(SyncOutcome.loggedOut);
    }

    var sent = 0;
    final rejected = <PendingAction>[];

    for (final action in await outbox.all()) {
      if (action.isRejected) continue;

      try {
        await dio.request<Object?>(
          action.path,
          data: action.body,
          options: Options(
            method: action.method,
            headers: {'Idempotency-Key': action.key},
          ),
        );
        await outbox.remove(action.localId!);
        sent++;
      } on DioException catch (error) {
        final status = error.response?.statusCode;

        // Réseau coupé ou serveur indisponible : on s'arrête et on garde l'ordre.
        if (status == null || status >= 500) {
          await outbox.update(action.copyWith(attempts: action.attempts + 1));
          return SyncReport(
            SyncOutcome.offline,
            sent: sent,
            rejected: rejected,
          );
        }
        if (status == 401) {
          return SyncReport(
            SyncOutcome.unauthorized,
            sent: sent,
            rejected: rejected,
          );
        }

        // Refus métier (offre épuisée, code faux…) : définitif, l'utilisateur est prévenu.
        final message = ApiException.fromDio(error).message;
        final refused = action.copyWith(error: message);
        await outbox.update(refused);
        rejected.add(refused);
        await notifications.show(
          4999000 + (action.localId! % 1000),
          'Action refusée',
          '${action.label} : $message',
        );
      }
    }

    try {
      final response = await dio.get<Map<String, dynamic>>(ApiEndpoints.sync);
      await store.saveSnapshot(response.data!);
    } on DioException catch (error) {
      final outcome = error.response?.statusCode == 401
          ? SyncOutcome.unauthorized
          : SyncOutcome.offline;
      return SyncReport(outcome, sent: sent, rejected: rejected);
    }

    await notifications.showNewServerNotifications(store);
    await notifications.reschedule(store);
    return SyncReport(SyncOutcome.done, sent: sent, rejected: rejected);
  }
}
