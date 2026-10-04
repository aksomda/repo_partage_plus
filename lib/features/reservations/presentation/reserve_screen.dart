import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_fields.dart';
import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/reservations/data/reservations_repository.dart';

/// Réservation d'une offre publiée par un compte, avec ou sans compte. Offre payante : paiement
/// hors application, puis saisie de la référence de la transaction.
class ReserveScreen extends ConsumerWidget {
  const ReserveScreen({super.key, required this.offerId});

  final int offerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offer = ref.watch(offerDetailProvider(offerId));
    return Scaffold(
      appBar: AppBar(title: const Text('Réserver')),
      body: offer.when(
        data: (data) => isGuestOffer(data)
            ? Center(
                child: EmptyState(
                  icon: Icons.call_outlined,
                  title: 'Offre publiée sans compte',
                  message:
                      'Elle ne se réserve pas : appelez le donateur au '
                      '${data['contact_phone'] ?? ''} pour convenir du retrait.',
                ),
              )
            : _ReserveForm(offer: data),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: EmptyState(
            icon: Icons.search_off,
            title: 'Offre indisponible',
            message: '$error',
          ),
        ),
      ),
    );
  }
}

class _ReserveForm extends ConsumerStatefulWidget {
  const _ReserveForm({required this.offer});

  final Json offer;

  @override
  ConsumerState<_ReserveForm> createState() => _ReserveFormState();
}

class _ReserveFormState extends ConsumerState<_ReserveForm> {
  final _form = GlobalKey<FormState>();
  final _guest = GuestFieldsController();
  final _reference = TextEditingController();
  var _quantity = 1;
  var _loading = false;

  Json get _offer => widget.offer;
  num get _price => _offer['price'] as num? ?? 0;
  int get _available => _offer['quantity_available'] as int? ?? 1;

  @override
  void dispose() {
    _guest.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    final reference = _price > 0 ? _reference.text.trim() : null;
    final loggedIn = ref.read(authTokenProvider) != null;

    try {
      if (loggedIn) {
        final result = await ref
            .read(reservationsRepositoryProvider)
            .reserve(
              offerId: _offer['id'] as int,
              offerTitle: _offer['title'] as String,
              quantity: _quantity,
              paymentReference: reference,
            );
        if (!mounted) return;
        switch (result) {
          case Sent():
            showMessage(context, 'Réservation enregistrée');
            context.go(AppRoutes.myReservations);
          case Queued():
            showMessage(
              context,
              'Hors ligne : la réservation sera envoyée au retour du réseau',
            );
            context.go(AppRoutes.myReservations);
          case Rejected(:final message):
            showMessage(context, message, error: true);
        }
      } else {
        final created = await ref
            .read(guestRepositoryProvider)
            .reserve(
              offerId: _offer['id'] as int,
              quantity: _quantity,
              paymentReference: reference,
              guest: _guest.value,
            );
        if (!mounted) return;
        // Quantités à jour pour les autres visiteurs de l'appareil.
        ref.read(syncControllerProvider.notifier).syncNow();
        context.go(AppRoutes.confirmation('${created['id']}'));
      }
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authTokenProvider) != null;
    final paymentInfo = _offer['payment_info'] as String?;

    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  OfferThumbnail(offer: _offer, size: 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _offer['title'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '${formatPrice(_price)} · ${_offer['donor_name']}',
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Créneau de retrait',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: AppColors.primary),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(formatPickup(_offer))),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Quantité',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton.outlined(
                tooltip: 'Moins',
                onPressed: _quantity > 1
                    ? () => setState(() => _quantity--)
                    : null,
                icon: const Icon(Icons.remove),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '$_quantity',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton.outlined(
                tooltip: 'Plus',
                onPressed: _quantity < _available
                    ? () => setState(() => _quantity++)
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          Text(
            '$_available ${_offer['unit']}(s) disponible(s)',
            style: const TextStyle(color: AppColors.textMuted),
          ),
          if (_price > 0) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'À payer : ${formatPrice(_price * _quantity)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(paymentInfo ?? 'Contactez le donateur pour payer.'),
                  const SizedBox(height: 4),
                  const Text(
                    'Payez d’abord hors de l’application, puis saisissez '
                    'la référence reçue (SMS de confirmation).',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            LabeledField(
              label: 'Référence de la transaction',
              child: TextFormField(
                controller: _reference,
                decoration: const InputDecoration(
                  hintText: 'Ex. : OM240929.1234.A56789',
                ),
                validator: (value) =>
                    RegExp(
                      r'^[A-Za-z0-9.\-_/ ]{4,64}$',
                    ).hasMatch(value?.trim() ?? '')
                    ? null
                    : 'Référence obligatoire (4 caractères minimum)',
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (!loggedIn)
            GuestFields(
              controller: _guest,
              returnTo: AppRoutes.reserve(_offer['id'] as int),
              notice:
                  'Réservez sans compte : le donateur verra votre nom et votre '
                  'téléphone. Votre réservation reste consultable sur cet '
                  'appareil.',
            ),
          LoadingButton(
            label: 'Confirmer la réservation',
            loading: _loading,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
