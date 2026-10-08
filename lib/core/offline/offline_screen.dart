import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';

/// Mode hors ligne (maquette) : ce qui reste consultable sur l'appareil,
/// et les actions qui partiront au retour du réseau. Ouvert en touchant le
/// bandeau « Hors ligne ».
class OfflineScreen extends ConsumerWidget {
  const OfflineScreen({super.key});

  /// Liste des offres favorites (gardées sur l'appareil).
  void _showFavorites(BuildContext context, WidgetRef ref) {
    final filters = ref.read(offerFiltersProvider);
    ref
        .read(offerFiltersProvider.notifier)
        .apply(filters.copyWith(favoritesOnly: true));
    context.go(AppRoutes.search);
  }

  void _close(BuildContext context) =>
      context.canPop() ? context.pop() : context.go(AppRoutes.home);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(syncControllerProvider.select((s) => s.online));
    final waiting = ref.watch(waitingActionsProvider).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Mode hors ligne')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: const BoxDecoration(
                      color: AppColors.primarySoft,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      online ? Icons.wifi : Icons.wifi_off,
                      size: 52,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  online ? 'De nouveau en ligne' : 'Mode hors ligne',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  online
                      ? 'La connexion est revenue : vos données se mettent à '
                            'jour.'
                      : 'Vous pouvez toujours consulter vos offres favorites '
                            'et vos réservations enregistrées.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                if (waiting > 0) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.accentSoft,
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.cloud_upload_outlined,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            waiting == 1
                                ? '1 action sera envoyée au retour du réseau.'
                                : '$waiting actions seront envoyées au '
                                      'retour du réseau.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: () => _showFavorites(context, ref),
                  icon: const Icon(Icons.favorite_border),
                  label: const Text('Voir mes favoris'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => context.go(AppRoutes.myReservations),
                  icon: const Icon(Icons.event_note_outlined),
                  label: const Text('Mes réservations'),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: online
                      ? () {
                          ref.read(syncControllerProvider.notifier).syncNow();
                          _close(context);
                        }
                      : () => _close(context),
                  child: Text(
                    online
                        ? 'Synchroniser maintenant'
                        : 'Synchroniser plus tard',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
