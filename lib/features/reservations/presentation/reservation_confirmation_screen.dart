import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/maps/osmand_button.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/pickup/domain/pickup_qr.dart';
import 'package:repo_partage_plus/features/reservations/data/reservations_repository.dart';

/// Réservation (compte ou invité) retrouvée dans les données de l'appareil.
final localReservationProvider = Provider.family<Json?, int>((ref, id) {
  final guest = ref.watch(guestReservationsProvider).value ?? const [];
  for (final reservation in [...guest, ...ref.watch(myReservationsProvider)]) {
    if (reservation['id'] == id) return reservation;
  }
  return null;
});

/// Code de retrait et récapitulatif d'une réservation.
class ReservationConfirmationScreen extends ConsumerWidget {
  const ReservationConfirmationScreen({super.key, required this.reservationId});

  final String reservationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = int.tryParse(reservationId);
    final reservation = id == null
        ? null
        : ref.watch(localReservationProvider(id));

    return Scaffold(
      appBar: AppBar(title: const Text('Confirmation de réservation')),
      body: reservation == null
          ? Center(
              child: EmptyState(
                icon: Icons.event_busy,
                title: 'Réservation introuvable sur cet appareil',
                action: OutlinedButton(
                  onPressed: () => context.go(AppRoutes.myReservations),
                  child: const Text('Mes réservations'),
                ),
              ),
            )
          : _Summary(reservation: reservation),
    );
  }
}

class _Summary extends ConsumerStatefulWidget {
  const _Summary({required this.reservation});

  final Json reservation;

  @override
  ConsumerState<_Summary> createState() => _SummaryState();
}

class _SummaryState extends ConsumerState<_Summary> {
  var _cancelling = false;

  Json get _r => widget.reservation;
  bool get _isGuest => _r['guest_token'] != null;

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Annuler la réservation ?'),
        content: const Text('La quantité sera rendue aux autres personnes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Garder'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Annuler la réservation'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _cancelling = true);
    try {
      if (_isGuest) {
        await ref.read(guestRepositoryProvider).cancelReservation(_r);
      } else {
        final result = await ref
            .read(reservationsRepositoryProvider)
            .cancel(_r);
        if (result case Rejected(:final message)) throw Exception(message);
      }
      if (mounted) showMessage(context, 'Réservation annulée');
    } catch (error) {
      if (mounted) showMessage(context, '$error', error: true);
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _r['status'] as String? ?? 'pending';
    final code = _r['pickup_code'] as String?;
    final amount = _r['amount'] as num? ?? 0;
    final active = status == 'pending' || status == 'confirmed';
    final guestOffer =
        _r['is_guest_offer'] == 1 || _r['is_guest_offer'] == true;

    return RefreshIndicator(
      onRefresh: () async {
        if (_isGuest) {
          await ref.read(guestRepositoryProvider).refresh();
        } else {
          await ref.read(syncControllerProvider.notifier).syncNow();
        }
      },
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                active ? Icons.check : Icons.close,
                size: 40,
                color: active ? AppColors.primary : AppColors.danger,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(child: StatusBadge(status)),
          const SizedBox(height: 8),
          Text(
            status == 'pending'
                ? 'En attente de confirmation par le donateur'
                : status == 'confirmed'
                ? 'Réservation confirmée'
                : 'Réservation ${status == 'cancelled' ? 'annulée' : 'terminée'}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          const SizedBox(height: 24),
          if (code != null && active) ...[
            const Text(
              'Code de récupération',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.primary, width: 1.5),
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    code,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 8,
                      color: AppColors.primary,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copier',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      showMessage(context, 'Code copié');
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                ),
                child: QrImageView(
                  key: const ValueKey('pickup-qr'),
                  data: pickupQrData(_r['id'], code),
                  size: 180,
                  semanticsLabel: 'QR code de retrait',
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Présentez ce code ou ce QR code au donateur lors du retrait.',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 20),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_r['offer_title'] ?? ''}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _row(
                    Icons.inventory_2_outlined,
                    'Quantité : ${_r['quantity']}',
                  ),
                  if (_r['pickup_start'] != null)
                    _row(Icons.schedule, formatPickup(_r)),
                  if (_r['address'] != null)
                    _row(Icons.location_on_outlined, '${_r['address']}'),
                  if (_r['donor_name'] != null)
                    _row(Icons.storefront_outlined, '${_r['donor_name']}'),
                  if (_r['donor_phone'] != null &&
                      (guestOffer || status == 'confirmed'))
                    _row(Icons.phone_outlined, '${_r['donor_phone']}'),
                  if (amount > 0) ...[
                    _row(
                      Icons.payments_outlined,
                      'Payé : ${formatPrice(amount)}',
                    ),
                    _row(
                      Icons.receipt_long_outlined,
                      'Réf. : ${_r['payment_reference']}',
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (active && _r['latitude'] != null) ...[
            const SizedBox(height: 12),
            OsmAndButton(
              lat: (_r['latitude'] as num).toDouble(),
              lng: (_r['longitude'] as num).toDouble(),
              label: '${_r['offer_title'] ?? 'Retrait'}',
            ),
          ],
          if (guestOffer && active)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Le donateur n’a pas de compte : appelez-le pour convenir du '
                'retrait.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          if (_isGuest)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Réservation sans compte : elle n’est consultable que sur cet '
                'appareil (Réservations).',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => context.go(AppRoutes.home),
            child: const Text('Retour aux offres'),
          ),
          if (active && _r['local'] != true) ...[
            const SizedBox(height: 8),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: _cancelling ? null : _cancel,
              child: const Text('Annuler la réservation'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.textMuted),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
