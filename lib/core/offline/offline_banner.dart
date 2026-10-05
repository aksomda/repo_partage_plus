import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/offline/sync_service.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';

/// Bandeau affiché au-dessus de tous les écrans quand l'appareil est hors
/// ligne ou que des actions attendent d'être envoyées.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key, required this.child});

  final Widget child;

  /// Écran de connexion, adresse pré-remplie ; la session n'est pas
  /// effacée : reconnecté au même compte, les actions en attente partent.
  void _reconnect(WidgetRef ref) {
    final email = ref.read(profileProvider)?['email'] as String?;
    ref
        .read(routerProvider)
        .go(email == null ? AppRoutes.login : AppRoutes.loginWith(email));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final waiting = ref.watch(waitingActionsProvider).length;
    final colors = Theme.of(context).colorScheme;

    // Session refusée (expirée, ou compte supprimé du serveur) : sans
    // reconnexion, plus rien ne part ; on le dit et on propose de le faire.
    final refused =
        sync.online &&
        !sync.syncing &&
        sync.lastOutcome == SyncOutcome.unauthorized;

    final String? message;
    if (refused) {
      message = waiting == 0
          ? 'Session refusée par le serveur : reconnectez-vous'
          : 'Session refusée par le serveur : reconnectez-vous pour envoyer '
                'vos $waiting action(s) en attente';
    } else if (!sync.online) {
      message = waiting == 0
          ? 'Hors ligne : données de la dernière synchronisation'
          : 'Hors ligne : $waiting action(s) seront envoyées au retour du réseau';
    } else if (sync.syncing) {
      message = 'Synchronisation…';
    } else if (waiting > 0) {
      message = '$waiting action(s) en attente d’envoi';
    } else {
      message = null;
    }

    // Hors ligne : bandeau vert foncé ; synchro ou attente : orange pâle.
    final background = sync.online ? colors.secondaryContainer : colors.primary;
    final foreground = sync.online
        ? colors.onSecondaryContainer
        : colors.onPrimary;

    return Column(
      children: [
        if (message != null)
          Material(
            color: background,
            child: SafeArea(
              bottom: false,
              child: InkWell(
                onTap: refused
                    ? () => _reconnect(ref)
                    : sync.online
                    ? ref.read(syncControllerProvider.notifier).syncNow
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        sync.online ? Icons.sync : Icons.cloud_off,
                        size: 16,
                        color: foreground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          message,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: foreground,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                      if (sync.online && !sync.syncing)
                        Text(
                          refused ? 'Se reconnecter' : 'Synchroniser',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: foreground,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          // Le bandeau occupe déjà la zone système du haut.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: message != null,
            child: child,
          ),
        ),
      ],
    );
  }
}
