import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Modération a posteriori : les offres sont visibles dès leur publication,
/// l'administrateur retire celles qui sont abusives (avec ou sans compte).
class OfferModerationScreen extends ConsumerStatefulWidget {
  const OfferModerationScreen({super.key});

  @override
  ConsumerState<OfferModerationScreen> createState() =>
      _OfferModerationScreenState();
}

class _OfferModerationScreenState extends ConsumerState<OfferModerationScreen> {
  var _query = '';

  Future<void> _withdraw(Json offer) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _WithdrawDialog(title: offer['title'] as String),
    );
    if (reason == null) return;

    final result = await ref
        .read(adminRepositoryProvider)
        .withdrawOffer(offer, reason: reason);
    if (!mounted) return;
    switch (result) {
      case Sent():
        showMessage(context, 'Offre « ${offer['title']} » retirée');
      case Queued():
        showMessage(context, 'Hors ligne : le retrait sera envoyé plus tard');
      case Rejected(:final message):
        showMessage(context, message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final offers = ref
        .watch(moderationOffersProvider)
        .where(
          (offer) =>
              query.isEmpty ||
              [
                offer['title'],
                offer['donor_name'],
                offer['category_name'],
                offer['country_name'],
              ].whereType<String>().any(
                (value) => value.toLowerCase().contains(query),
              ),
        )
        .toList();
    final syncing = ref.watch(syncControllerProvider).syncing;

    return Scaffold(
      appBar: AppBar(title: const Text('Modération des offres')),
      drawer: AppMenu(
        currentLocation: GoRouterState.of(context).uri.toString(),
      ),
      body: RefreshIndicator(
        onRefresh: ref.read(syncControllerProvider.notifier).syncNow,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            const Text(
              'Les offres sont visibles dès leur publication. Retirez celles '
              'qui sont abusives : les réservations en cours sont annulées, '
              'le publieur est prévenu (notification et e-mail s’il en a '
              'laissé un).',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                hintText: 'Rechercher (titre, publieur, catégorie, pays)',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Text(
              'Offres visibles (${offers.length})',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (offers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: syncing
                      ? const CircularProgressIndicator()
                      : const Text(
                          'Aucune offre visible. Tirez vers le bas pour '
                          'actualiser.',
                          textAlign: TextAlign.center,
                        ),
                ),
              ),
            for (final offer in offers)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Stack(
                  children: [
                    OfferCard(
                      offer: offer,
                      onTap: () =>
                          context.push(AppRoutes.offer('${offer['id']}')),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.danger,
                        ),
                        onPressed: () => _withdraw(offer),
                        icon: const Icon(Icons.block, size: 18),
                        label: const Text('Retirer'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Motif du retrait, obligatoire (envoyé au publieur).
class _WithdrawDialog extends StatefulWidget {
  const _WithdrawDialog({required this.title});

  final String title;

  @override
  State<_WithdrawDialog> createState() => _WithdrawDialogState();
}

class _WithdrawDialogState extends State<_WithdrawDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.of(context).pop(_reason.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Retirer « ${widget.title} » ?'),
      content: Form(
        key: _form,
        child: TextFormField(
          controller: _reason,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Motif (envoyé au publieur)',
          ),
          validator: (value) =>
              (value?.trim().length ?? 0) < 3 ? 'Motif obligatoire' : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: _submit,
          child: const Text('Retirer'),
        ),
      ],
    );
  }
}
