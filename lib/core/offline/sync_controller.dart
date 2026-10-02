import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/notifications/local_notifications.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_service.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

/// true si l'appareil a une connexion réseau (Wi-Fi, mobile…).
/// Une connexion sans Internet est détectée à l'envoi, qui échoue proprement.
final onlineProvider = StreamProvider<bool>((ref) async* {
  final connectivity = Connectivity();
  bool isOnline(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  yield isOnline(await connectivity.checkConnectivity());
  yield* connectivity.onConnectivityChanged.map(isOnline).distinct();
});

final outboxProvider = Provider<Outbox>(
  (ref) => Outbox(ref.watch(localStoreProvider).db),
);

final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(
    dio: ref.watch(dioProvider),
    store: ref.watch(localStoreProvider),
    outbox: ref.watch(outboxProvider),
    notifications: ref.watch(localNotificationsProvider),
  ),
);

class SyncState {
  const SyncState({
    this.online = false,
    this.syncing = false,
    this.lastOutcome,
    this.lastSync,
  });

  final bool online;
  final bool syncing;
  final SyncOutcome? lastOutcome;
  final DateTime? lastSync;

  SyncState copyWith({
    bool? online,
    bool? syncing,
    SyncOutcome? lastOutcome,
    DateTime? lastSync,
  }) {
    return SyncState(
      online: online ?? this.online,
      syncing: syncing ?? this.syncing,
      lastOutcome: lastOutcome ?? this.lastOutcome,
      lastSync: lastSync ?? this.lastSync,
    );
  }
}

/// Résultat d'une action faite par l'utilisateur.
sealed class SubmitResult {
  const SubmitResult();
}

/// Acceptée par le serveur.
class Sent extends SubmitResult {
  const Sent();
}

/// Hors ligne : enregistrée, sera envoyée au retour du réseau.
class Queued extends SubmitResult {
  const Queued(this.action);
  final PendingAction action;
}

/// Refusée par le serveur (offre épuisée, code incorrect…).
class Rejected extends SubmitResult {
  const Rejected(this.message);
  final String message;
}

/// Orchestre la synchronisation : au démarrage, au retour du réseau,
/// toutes les [period] et après chaque action de l'utilisateur.
class SyncController extends Notifier<SyncState> {
  static const period = Duration(minutes: 2);

  Future<SyncReport>? _running;

  @override
  SyncState build() {
    final timer = Timer.periodic(period, (_) {
      if (state.online) syncNow();
    });
    ref.onDispose(timer.cancel);

    ref.listen(onlineProvider, (previous, next) {
      final online = next.value ?? false;
      final wasOnline = previous?.value ?? false;
      state = state.copyWith(online: online);
      if (online && !wasOnline) syncNow();
    });

    return SyncState(online: ref.read(onlineProvider).value ?? false);
  }

  /// Lance une synchronisation (une seule à la fois).
  Future<SyncReport> syncNow() {
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  Future<SyncReport> _sync() async {
    state = state.copyWith(syncing: true);
    final report = await ref.read(syncServiceProvider).sync();
    state = state.copyWith(
      syncing: false,
      lastOutcome: report.outcome,
      lastSync: report.outcome == SyncOutcome.done ? DateTime.now() : null,
    );
    return report;
  }

  /// Enregistre l'action, puis tente de l'envoyer tout de suite.
  Future<SubmitResult> submit(PendingAction action) async {
    final saved = await ref.read(outboxProvider).add(action);
    if (!state.online) return Queued(saved);

    await (_running ?? Future<void>.value());
    await syncNow();

    final after = await ref.read(outboxProvider).get(saved.localId!);
    if (after == null) return const Sent();
    if (after.isRejected) return Rejected(after.error!);
    return Queued(after);
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);
