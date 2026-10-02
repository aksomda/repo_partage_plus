import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/reservations/data/reservations_repository.dart';

/// Réservations : celles du compte (historique complet) et celles faites
/// sans compte sur cet appareil.
class MyReservationsScreen extends ConsumerStatefulWidget {
  const MyReservationsScreen({super.key});

  @override
  ConsumerState<MyReservationsScreen> createState() =>
      _MyReservationsScreenState();
}

class _MyReservationsScreenState extends ConsumerState<MyReservationsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(ref.read(guestRepositoryProvider).refresh);
  }

  Future<void> _refresh() async {
    await ref.read(guestRepositoryProvider).refresh();
    await ref.read(syncControllerProvider.notifier).syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authTokenProvider) != null;
    final account = loggedIn
        ? ref.watch(myReservationsProvider)
        : const <Json>[];
    final guest = ref.watch(guestReservationsProvider).value ?? const <Json>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Mes réservations')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!loggedIn) const _LoginHint(),
            if (account.isEmpty && guest.isEmpty)
              EmptyState(
                icon: Icons.event_note_outlined,
                title: 'Aucune réservation',
                message:
                    'Réservez une offre à proximité : elle apparaîtra ici.',
                action: FilledButton(
                  onPressed: () => context.go(AppRoutes.home),
                  child: const Text('Voir les offres'),
                ),
              ),
            for (final reservation in account)
              _ReservationTile(reservation: reservation),
            if (guest.isNotEmpty) ...[
              if (loggedIn)
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Text(
                    'Faites sans compte sur cet appareil',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              for (final reservation in guest)
                _ReservationTile(reservation: reservation),
            ],
          ],
        ),
      ),
      bottomNavigationBar: const AppBottomNav(current: 3),
    );
  }
}

class _LoginHint extends StatelessWidget {
  const _LoginHint();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.primarySoft,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: AppColors.primary),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Sans compte, seules les réservations faites sur cet appareil '
                'sont affichées.',
              ),
            ),
            TextButton(
              onPressed: () =>
                  context.push(AppRoutes.loginThen(AppRoutes.myReservations)),
              child: const Text('Se connecter'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReservationTile extends StatelessWidget {
  const _ReservationTile({required this.reservation});

  final Json reservation;

  @override
  Widget build(BuildContext context) {
    final local = reservation['local'] == true;
    final status = reservation['status'] as String? ?? 'pending';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          leading: const CircleAvatar(
            backgroundColor: AppColors.primarySoft,
            foregroundColor: AppColors.primary,
            child: Icon(Icons.shopping_bag_outlined),
          ),
          title: Text(
            '${reservation['offer_title'] ?? 'Offre'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (reservation['pickup_start'] != null)
                Text(formatPickup(reservation)),
              const SizedBox(height: 4),
              StatusBadge(status),
            ],
          ),
          trailing: local ? null : const Icon(Icons.chevron_right),
          onTap: local
              ? null
              : () => context.push(
                  AppRoutes.confirmation('${reservation['id']}'),
                ),
        ),
      ),
    );
  }
}
