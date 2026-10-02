import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Publications : celles du compte, et celles faites sans compte sur cet
/// appareil (retirables grâce à leur jeton).
class MyOffersScreen extends ConsumerStatefulWidget {
  const MyOffersScreen({super.key});

  @override
  ConsumerState<MyOffersScreen> createState() => _MyOffersScreenState();
}

class _MyOffersScreenState extends ConsumerState<MyOffersScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(ref.read(guestRepositoryProvider).refresh);
  }

  Future<void> _withdraw(Json offer, {required bool guest}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Retirer « ${offer['title']} » ?'),
        content: const Text('Les réservations en cours seront annulées.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Garder'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      if (guest) {
        await ref.read(guestRepositoryProvider).withdrawOffer(offer);
      } else {
        final result = await ref
            .read(offersRepositoryProvider)
            .withdraw(offer['id'] as int, offer['title'] as String);
        if (result case Rejected(:final message)) throw Exception(message);
      }
      if (mounted) showMessage(context, 'Offre retirée');
    } catch (error) {
      if (mounted) showMessage(context, '$error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authTokenProvider) != null;
    final account = loggedIn ? ref.watch(myOffersProvider) : const <Json>[];
    final guest = ref.watch(guestOffersProvider).value ?? const <Json>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Mes offres')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(AppRoutes.createOffer),
        backgroundColor: AppColors.primary,
        shape: const StadiumBorder(),
        icon: const Icon(Icons.add),
        label: const Text('Publier'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(guestRepositoryProvider).refresh();
          await ref.read(syncControllerProvider.notifier).syncNow();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            if (!loggedIn)
              Card(
                color: AppColors.primarySoft,
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text(
                    'Connectez-vous pour suivre toutes vos publications et '
                    'confirmer les retraits.',
                  ),
                  trailing: TextButton(
                    onPressed: () =>
                        context.push(AppRoutes.loginThen(AppRoutes.myOffers)),
                    child: const Text('Connexion'),
                  ),
                ),
              ),
            if (account.isEmpty && guest.isEmpty)
              const EmptyState(
                icon: Icons.volunteer_activism_outlined,
                title: 'Aucune publication',
                message:
                    'Publiez vos invendus ou surplus : ils seront visibles '
                    'après validation.',
              ),
            for (final offer in account)
              _OfferTile(
                offer: offer,
                onWithdraw: offer['local'] == true
                    ? null
                    : () => _withdraw(offer, guest: false),
              ),
            if (guest.isNotEmpty && loggedIn)
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Text(
                  'Publiées sans compte sur cet appareil',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            for (final offer in guest)
              _OfferTile(
                offer: offer,
                onWithdraw: () => _withdraw(offer, guest: true),
              ),
          ],
        ),
      ),
    );
  }
}

class _OfferTile extends StatelessWidget {
  const _OfferTile({required this.offer, required this.onWithdraw});

  final Json offer;
  final VoidCallback? onWithdraw;

  @override
  Widget build(BuildContext context) {
    final status = offer['status'] as String? ?? 'pending';
    final open = const {'pending', 'published', 'reserved'}.contains(status);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              OfferThumbnail(offer: offer, size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${offer['title']}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${offer['quantity_available'] ?? offer['quantity']} '
                      '${offer['unit'] ?? ''} · ${formatPrice(offer['price'] as num?)}',
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 4),
                    StatusBadge(status),
                    if (status == 'pending')
                      const Text(
                        'Visible après validation par un modérateur',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (open && onWithdraw != null)
                IconButton(
                  tooltip: 'Retirer l’offre',
                  icon: const Icon(Icons.delete_outline),
                  color: AppColors.danger,
                  onPressed: onWithdraw,
                ),
              if (offer['id'] != null && offer['local'] != true)
                IconButton(
                  tooltip: 'Voir',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () =>
                      context.push(AppRoutes.offer('${offer['id']}')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
