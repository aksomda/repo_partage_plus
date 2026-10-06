import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/admin/data/admin_repository.dart';
import 'package:repo_partage_plus/features/admin/presentation/widgets/admin_shell.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Réservations de toute la plateforme, en lecture seule : lues dans la copie
/// locale (synchronisée avec MySQL), donc consultables hors ligne.
class AdminReservationsScreen extends ConsumerStatefulWidget {
  const AdminReservationsScreen({super.key});

  @override
  ConsumerState<AdminReservationsScreen> createState() =>
      _AdminReservationsScreenState();
}

class _AdminReservationsScreenState
    extends ConsumerState<AdminReservationsScreen> {
  static const _tabs = [
    (label: 'Toutes', status: null),
    (label: 'En attente', status: 'pending'),
    (label: 'Confirmées', status: 'confirmed'),
    (label: 'Retirées', status: 'picked_up'),
    (label: 'Annulées', status: 'cancelled'),
  ];

  var _tab = 0;
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(adminReservationsProvider);
    final hasSnapshot = ref.watch(snapshotProvider('admin')).value != null;

    final found = [
      for (final r in all)
        if (matchesSearch(
          '${r['offer_title'] ?? ''} ${r['donor_name'] ?? ''} '
          '${r['beneficiary_name'] ?? ''} ${r['payment_reference'] ?? ''}',
          _query,
        ))
          r,
    ];
    int count(String? status) => status == null
        ? found.length
        : found.where((r) => r['status'] == status).length;
    final status = _tabs[_tab].status;
    final reservations = status == null
        ? found
        : found.where((r) => r['status'] == status).toList();

    return AdminShell(
      title: 'Réservations de la plateforme',
      current: AppRoutes.adminReservations,
      actions: const [AdminSyncButton()],
      builder: (context, wide) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: AppColors.surface,
            padding: EdgeInsets.fromLTRB(
              wide ? 24 : 16,
              16,
              wide ? 24 : 16,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Réservations de la plateforme',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (index, tab) in _tabs.indexed)
                          ChoiceChip(
                            label: Text('${tab.label} (${count(tab.status)})'),
                            selected: _tab == index,
                            onSelected: (_) => setState(() => _tab = index),
                          ),
                      ],
                    ),
                    SizedBox(
                      width: wide ? 280 : double.infinity,
                      child: TextField(
                        onChanged: (value) => setState(() => _query = value),
                        decoration: const InputDecoration(
                          hintText: 'Offre, donateur, bénéficiaire…',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => refreshAdminData(context, ref),
              child: reservations.isEmpty
                  ? AdminEmptyMessage(
                      icon: Icons.event_busy_outlined,
                      text: !hasSnapshot
                          ? 'Aucune copie locale des réservations.\n'
                                'Connectez-vous à Internet pour la télécharger.'
                          : all.isEmpty
                          ? 'Aucune réservation'
                          : 'Aucune réservation trouvée',
                    )
                  : wide
                  ? _ReservationsTable(reservations: reservations)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: reservations.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _ReservationCard(reservation: reservations[index]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget reservationStatusBadge(Object? status) => switch (status) {
  'pending' => const AdminBadge(
    'En attente',
    AppColors.accentSoft,
    AppColors.accent,
  ),
  'confirmed' => const AdminBadge(
    'Confirmée',
    Color(0xFFE3F0FB),
    Color(0xFF1565C0),
  ),
  'picked_up' => const AdminBadge(
    'Retirée',
    AppColors.primarySoft,
    AppColors.primary,
  ),
  _ => const AdminBadge('Annulée', Color(0xFFFDE7E7), AppColors.danger),
};

String _quantity(Json r) =>
    '${formatNumber(r['quantity'] as num?)} ${r['unit'] ?? ''}'.trim();

Future<void> _showDetails(BuildContext context, Json r) {
  final amount = num.tryParse('${r['amount'] ?? 0}') ?? 0;
  final rows = [
    ('Offre', r['offer_title'] as String? ?? '—'),
    ('Quantité', _quantity(r)),
    (
      'Donateur',
      '${r['donor_name'] ?? '—'}${r['is_guest_offer'] == 1 || r['is_guest_offer'] == true ? ' (sans compte)' : ''}',
    ),
    ('Téléphone du donateur', r['donor_phone'] as String? ?? '—'),
    ('Bénéficiaire', r['beneficiary_name'] as String? ?? '—'),
    ('Téléphone du bénéficiaire', r['beneficiary_phone'] as String? ?? '—'),
    ('Lieu de retrait', r['address'] as String? ?? '—'),
    if (amount > 0) ('Montant', '${formatNumber(amount)} FCFA'),
    if (r['payment_reference'] != null)
      ('Référence de paiement', r['payment_reference'] as String),
    ('Réservée le', formatAdminDate(r['created_at'], time: true)),
    if (r['picked_up_at'] != null)
      ('Retirée le', formatAdminDate(r['picked_up_at'], time: true)),
    if (r['cancelled_at'] != null)
      ('Annulée le', formatAdminDate(r['cancelled_at'], time: true)),
  ];
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Réservation n° ${r['id']}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            reservationStatusBadge(r['status']),
            const SizedBox(height: 12),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    SelectableText(value),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}

class _ReservationsTable extends StatelessWidget {
  const _ReservationsTable({required this.reservations});

  final List<Json> reservations;

  static const _headerStyle = TextStyle(
    color: AppColors.textMuted,
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );

  Widget _row(List<Widget> cells) {
    const flex = [3, 2, 2, 1, 2, 2];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          for (final (i, cell) in cells.indexed)
            Expanded(
              flex: flex[i],
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: cell,
              ),
            ),
        ],
      ),
    );
  }

  Text _text(Object? value, {bool bold = false}) => Text(
    '${value ?? '—'}',
    overflow: TextOverflow.ellipsis,
    style: bold ? const TextStyle(fontWeight: FontWeight.w600) : null,
  );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                color: AppColors.background,
                child: _row([
                  for (final title in [
                    'Offre',
                    'Donateur',
                    'Bénéficiaire',
                    'Quantité',
                    'Statut',
                    'Réservée le',
                  ])
                    Text(title, style: _headerStyle),
                ]),
              ),
              for (final (index, r) in reservations.indexed) ...[
                if (index > 0) const Divider(height: 1),
                InkWell(
                  onTap: () => _showDetails(context, r),
                  child: _row([
                    _text(r['offer_title'], bold: true),
                    _text(r['donor_name']),
                    _text(r['beneficiary_name']),
                    _text(_quantity(r)),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: reservationStatusBadge(r['status']),
                    ),
                    _text(formatAdminDate(r['created_at'])),
                  ]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ReservationCard extends StatelessWidget {
  const _ReservationCard({required this.reservation});

  final Json reservation;

  @override
  Widget build(BuildContext context) {
    final r = reservation;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: () => _showDetails(context, r),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      r['offer_title'] as String? ?? '—',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  reservationStatusBadge(r['status']),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${r['donor_name'] ?? '—'} → ${r['beneficiary_name'] ?? '—'}',
                style: const TextStyle(color: AppColors.textMuted),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '${_quantity(r)} · ${formatAdminDate(r['created_at'])}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
