import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/reservations/data/reservations_repository.dart';
import 'package:repo_partage_plus/core/widgets/app_menu.dart';

/// Écran des réservations adaptatif :
/// - qui publie (donateur, ou tout compte ayant des offres ou des commandes
///   reçues) : onglets « Commandes reçues » et « Mes réservations » ;
/// - sinon : liste directe de ses propres réservations.
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
    final profile = ref.watch(profileProvider);
    final receivedOrders = loggedIn
        ? ref.watch(receivedReservationsProvider)
        : const <Json>[];
    // Tous les comptes (sauf admin) peuvent publier : un bénéficiaire ou une
    // association qui a publié doit aussi confirmer et valider les retraits.
    final isDonor =
        loggedIn &&
        profile != null &&
        profile['role'] != 'admin' &&
        (profile['role'] == 'donor' ||
            receivedOrders.isNotEmpty ||
            ref.watch(myOffersProvider).isNotEmpty);

    final accountReservations = loggedIn
        ? ref.watch(myReservationsProvider)
        : const <Json>[];
    final guestReservations =
        ref.watch(guestReservationsProvider).value ?? const <Json>[];

    if (isDonor) {
      return DefaultTabController(
        length: 2,
        child: Scaffold(
          drawer: const AppMenu(currentLocation: AppRoutes.myReservations),
          appBar: AppBar(
            leading: backOrMenuButton(context),
            title: const Text('Commandes & Réservations'),
            bottom: TabBar(
              indicatorColor: AppColors.primary,
              indicatorWeight: 3,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.textMuted,
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
              unselectedLabelStyle: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Commandes reçues'),
                      if (receivedOrders.any((r) => r['status'] == 'pending'))
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: const ShapeDecoration(
                            color: AppColors.accent,
                            shape: StadiumBorder(),
                          ),
                          child: Text(
                            '${receivedOrders.where((r) => r['status'] == 'pending').length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Tab(text: 'Mes réservations'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _ReceivedOrdersList(orders: receivedOrders, onRefresh: _refresh),
              _MyReservationsList(
                accountReservations: accountReservations,
                guestReservations: guestReservations,
                loggedIn: loggedIn,
                onRefresh: _refresh,
              ),
            ],
          ),
          bottomNavigationBar: const AppBottomNav(current: 3),
        ),
      );
    }

    return Scaffold(
      drawer: const AppMenu(currentLocation: AppRoutes.myReservations),
      appBar: AppBar(
        leading: backOrMenuButton(context),
        title: const Text('Mes réservations'),
      ),
      body: _MyReservationsList(
        accountReservations: accountReservations,
        guestReservations: guestReservations,
        loggedIn: loggedIn,
        onRefresh: _refresh,
      ),
      bottomNavigationBar: const AppBottomNav(current: 3),
    );
  }
}

/// Vue de la liste des commandes reçues sur les offres d'un donateur.
/// Statut cherché dans l'historique des réservations.
enum HistoryStatus {
  all('Toutes'),
  active('En cours'),
  pickedUp('Retirées'),
  cancelled('Annulées');

  const HistoryStatus(this.label);

  final String label;

  bool accepts(Json reservation) {
    final status = reservation['status'];
    return switch (this) {
      all => true,
      // pending_sync : faite hors ligne, pas encore envoyée.
      active =>
        status == 'pending' ||
            status == 'confirmed' ||
            status == 'pending_sync',
      pickedUp => status == 'picked_up',
      cancelled => status == 'cancelled' || status == 'unavailable',
    };
  }
}

/// Période de l'historique, d'après la date de la réservation.
enum HistoryPeriod {
  all('Toutes les dates', null),
  week('7 derniers jours', Duration(days: 7)),
  month('30 derniers jours', Duration(days: 30));

  const HistoryPeriod(this.label, this.span);

  final String label;
  final Duration? span;

  bool accepts(Json reservation, DateTime now) {
    final span = this.span;
    if (span == null) return true;
    // Sans date (faite hors ligne, pas encore envoyée) : récente.
    final created = DateTime.tryParse('${reservation['created_at']}');
    return created == null || created.isAfter(now.subtract(span));
  }
}

/// Réservations correspondant au statut et à la période choisis.
List<Json> filterHistory(
  List<Json> reservations,
  HistoryStatus status,
  HistoryPeriod period, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return [
    for (final reservation in reservations)
      if (status.accepts(reservation) && period.accepts(reservation, at))
        reservation,
  ];
}

/// Filtres de l'historique : statut (avec le nombre de réservations) et
/// période.
class _HistoryFilterBar extends StatelessWidget {
  const _HistoryFilterBar({
    required this.all,
    required this.status,
    required this.period,
    required this.onStatus,
    required this.onPeriod,
  });

  final List<Json> all;
  final HistoryStatus status;
  final HistoryPeriod period;
  final ValueChanged<HistoryStatus> onStatus;
  final ValueChanged<HistoryPeriod> onPeriod;

  @override
  Widget build(BuildContext context) {
    final inPeriod = filterHistory(all, HistoryStatus.all, period);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final value in HistoryStatus.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(
                  '${value.label} '
                  '(${inPeriod.where(value.accepts).length})',
                ),
                selected: status == value,
                onSelected: (_) => onStatus(value),
              ),
            ),
          PopupMenuButton<HistoryPeriod>(
            tooltip: 'Période',
            initialValue: period,
            onSelected: onPeriod,
            itemBuilder: (_) => [
              for (final value in HistoryPeriod.values)
                PopupMenuItem(value: value, child: Text(value.label)),
            ],
            child: Chip(
              avatar: const Icon(Icons.date_range_outlined, size: 18),
              label: Text(period.label),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aucune réservation pour les filtres choisis.
class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const Text(
            'Aucune réservation pour ces filtres.',
            style: TextStyle(color: AppColors.textMuted),
          ),
          TextButton.icon(
            onPressed: onReset,
            icon: const Icon(Icons.filter_alt_off_outlined),
            label: const Text('Tout afficher'),
          ),
        ],
      ),
    );
  }
}

class _ReceivedOrdersList extends StatefulWidget {
  const _ReceivedOrdersList({required this.orders, required this.onRefresh});

  final List<Json> orders;
  final RefreshCallback onRefresh;

  @override
  State<_ReceivedOrdersList> createState() => _ReceivedOrdersListState();
}

class _ReceivedOrdersListState extends State<_ReceivedOrdersList> {
  var _status = HistoryStatus.all;
  var _period = HistoryPeriod.all;

  @override
  Widget build(BuildContext context) {
    final orders = widget.orders;
    final onRefresh = widget.onRefresh;
    if (orders.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Aucune commande reçue',
              message:
                  'Les réservations effectuées par des bénéficiaires sur vos offres apparaîtront ici.',
              action: OutlinedButton(
                onPressed: () => context.push(AppRoutes.myOffers),
                child: const Text('Gérer mes offres'),
              ),
            ),
          ],
        ),
      );
    }

    final shown = filterHistory(orders, _status, _period);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _HistoryFilterBar(
            all: orders,
            status: _status,
            period: _period,
            onStatus: (value) => setState(() => _status = value),
            onPeriod: (value) => setState(() => _period = value),
          ),
          if (shown.isEmpty)
            _NoMatch(
              onReset: () => setState(() {
                _status = HistoryStatus.all;
                _period = HistoryPeriod.all;
              }),
            ),
          for (final order in shown) _ReceivedOrderTile(order: order),
        ],
      ),
    );
  }
}

/// Carte individuelle d'une commande reçue avec actions (Confirmer / Retrait).
class _ReceivedOrderTile extends ConsumerStatefulWidget {
  const _ReceivedOrderTile({required this.order});

  final Json order;

  @override
  ConsumerState<_ReceivedOrderTile> createState() => _ReceivedOrderTileState();
}

class _ReceivedOrderTileState extends ConsumerState<_ReceivedOrderTile> {
  var _loading = false;

  Future<void> _confirmOrder() async {
    setState(() => _loading = true);
    try {
      final result = await ref
          .read(reservationsRepositoryProvider)
          .confirm(widget.order);
      if (!mounted) return;
      switch (result) {
        case Sent():
          showMessage(context, 'Réservation confirmée avec succès');
        case Queued():
          showMessage(
            context,
            'Hors ligne : la confirmation sera envoyée au retour du réseau',
          );
        case Rejected(:final message):
          showMessage(context, message, error: true);
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final status = order['status'] as String? ?? 'pending';
    final beneficiaryName =
        order['beneficiary_name'] as String? ?? 'Bénéficiaire';
    final beneficiaryPhone = order['beneficiary_phone'] as String?;
    final offerTitle = order['offer_title'] as String? ?? 'Offre';
    final quantity = order['quantity'] as num? ?? 1;
    final amount = order['amount'] as num? ?? 0;
    final paymentRef = order['payment_reference'] as String?;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: AppColors.primarySoft,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person_outline,
                      color: AppColors.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          beneficiaryName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (beneficiaryPhone != null &&
                            beneficiaryPhone.isNotEmpty)
                          Text(
                            beneficiaryPhone,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                  ),
                  StatusBadge(status),
                  if (order['beneficiary_id'] case final int beneficiaryId)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: IconButton(
                        tooltip: 'Écrire à $beneficiaryName',
                        visualDensity: VisualDensity.compact,
                        color: AppColors.primary,
                        icon: const Icon(Icons.chat_bubble_outline),
                        onPressed: () => context.push(
                          AppRoutes.directConversation(
                            beneficiaryId,
                            offerId: (order['offer_id'] as num?)?.toInt(),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const Divider(height: 24),
              Text(
                offerTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(
                    Icons.inventory_2_outlined,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Quantité : $quantity',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  if (amount > 0) ...[
                    const Spacer(),
                    Text(
                      formatPrice(amount),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ],
              ),
              if (order['pickup_start'] != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.schedule,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        formatPickup(order),
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
              if (paymentRef != null && paymentRef.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accentSoft,
                    borderRadius: BorderRadius.circular(AppTheme.radius / 2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.receipt_long_outlined,
                        size: 16,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Réf. paiement : $paymentRef',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (status == 'pending' || status == 'confirmed') ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (status == 'pending')
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _loading ? null : _confirmOrder,
                          icon: _loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.check_circle_outline,
                                  size: 18,
                                ),
                          label: const Text('Confirmer la commande'),
                        ),
                      ),
                    if (status == 'confirmed')
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              context.push(AppRoutes.pickup('${order['id']}')),
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: const Text('Valider le retrait'),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Vue de la liste des réservations effectuées par l'utilisateur.
class _MyReservationsList extends StatefulWidget {
  const _MyReservationsList({
    required this.accountReservations,
    required this.guestReservations,
    required this.loggedIn,
    required this.onRefresh,
  });

  final List<Json> accountReservations;
  final List<Json> guestReservations;
  final bool loggedIn;
  final RefreshCallback onRefresh;

  @override
  State<_MyReservationsList> createState() => _MyReservationsListState();
}

class _MyReservationsListState extends State<_MyReservationsList> {
  var _status = HistoryStatus.all;
  var _period = HistoryPeriod.all;

  void _reset() => setState(() {
    _status = HistoryStatus.all;
    _period = HistoryPeriod.all;
  });

  @override
  Widget build(BuildContext context) {
    final all = [...widget.accountReservations, ...widget.guestReservations];
    final accountReservations = filterHistory(
      widget.accountReservations,
      _status,
      _period,
    );
    final guestReservations = filterHistory(
      widget.guestReservations,
      _status,
      _period,
    );
    final loggedIn = widget.loggedIn;
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!loggedIn) const _LoginHint(),
          if (all.isNotEmpty)
            _HistoryFilterBar(
              all: all,
              status: _status,
              period: _period,
              onStatus: (value) => setState(() => _status = value),
              onPeriod: (value) => setState(() => _period = value),
            ),
          if (all.isNotEmpty &&
              accountReservations.isEmpty &&
              guestReservations.isEmpty)
            _NoMatch(onReset: _reset),
          if (all.isEmpty)
            EmptyState(
              icon: Icons.event_note_outlined,
              title: 'Aucune réservation',
              message: 'Réservez une offre à proximité : elle apparaîtra ici.',
              action: FilledButton(
                onPressed: () => context.go(AppRoutes.home),
                child: const Text('Voir les offres'),
              ),
            ),
          for (final reservation in accountReservations)
            _ReservationTile(reservation: reservation),
          if (guestReservations.isNotEmpty) ...[
            if (loggedIn)
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Text(
                  'Faites sans compte sur cet appareil',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            for (final reservation in guestReservations)
              _ReservationTile(reservation: reservation),
          ],
        ],
      ),
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
