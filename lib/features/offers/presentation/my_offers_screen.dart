import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/slots_editor.dart';

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

  /// Créneaux d'une offre déjà réservée (avec ou sans compte).
  Future<void> _editSlots(Json offer, {required bool guest}) async {
    final slots = await editPickupSlots(context, offer);
    if (slots == null || !mounted) return;
    final payload = slotsPayload(slots);
    try {
      if (guest) {
        await ref
            .read(guestRepositoryProvider)
            .updateOfferSlots(offer, payload);
        if (mounted) showMessage(context, 'Créneaux modifiés');
        return;
      }
      final result = await ref
          .read(offersRepositoryProvider)
          .updateSlots(offer['id'] as int, offer['title'] as String, payload);
      if (!mounted) return;
      switch (result) {
        case Sent():
          showMessage(context, 'Créneaux modifiés');
        case Queued():
          showMessage(
            context,
            'Hors ligne : les créneaux seront envoyés au retour du réseau',
          );
        case Rejected(:final message):
          showMessage(context, message, error: true);
      }
    } catch (error) {
      if (mounted) showMessage(context, '$error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authTokenProvider) != null;
    final account = loggedIn ? ref.watch(myOffersProvider) : const <Json>[];
    final guest = ref.watch(guestOffersProvider).value ?? const <Json>[];
    final insights = ref.watch(offerInsightsProvider);

    return Scaffold(
      appBar: AppBar(
        // Toujours présent : après une publication, l'historique est remis
        // à zéro, on revient alors à l'accueil.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Retour',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go(AppRoutes.home),
        ),
        title: const Text('Mes offres'),
      ),
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
            if (loggedIn && account.isNotEmpty) const _AdviceCard(),
            if (account.isEmpty && guest.isEmpty)
              const EmptyState(
                icon: Icons.volunteer_activism_outlined,
                title: 'Aucune publication',
                message:
                    'Publiez vos invendus ou surplus : ils sont visibles '
                    'tout de suite.',
              ),
            for (final offer in account)
              _OfferTile(
                offer: offer,
                insight: insights[offer['id']],
                onEditSlots: () => _editSlots(offer, guest: false),
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
                onEditSlots: () => _editSlots(offer, guest: true),
                onWithdraw: () => _withdraw(offer, guest: true),
              ),
          ],
        ),
      ),
    );
  }
}

/// Entièrement modifiable comme le permet le serveur : offre envoyée (avec
/// ou sans compte), publiée, et rien de réservé.
bool _editable(Json offer) =>
    offer['id'] != null &&
    offer['local'] != true &&
    const {'pending', 'published'}.contains(offer['status']) &&
    offer['quantity_available'] == offer['initial_quantity'];

/// Offre déjà réservée mais encore en cours : seuls ses créneaux changent.
bool _slotsEditable(Json offer) =>
    offer['id'] != null &&
    offer['local'] != true &&
    const {'published', 'reserved'}.contains(offer['status']) &&
    !_editable(offer);

class _OfferTile extends StatelessWidget {
  const _OfferTile({
    required this.offer,
    required this.onWithdraw,
    this.onEditSlots,
    this.insight,
  });

  final Json offer;
  final VoidCallback? onWithdraw;

  /// Modifier les créneaux d'une offre déjà réservée.
  final VoidCallback? onEditSlots;

  /// Risque de gaspillage et suggestions (offres en cours d'un compte).
  final Json? insight;

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
                    if (open && insight != null) WasteRisk(insight: insight!),
                    if (status == 'rejected' &&
                        offer['moderation_reason'] != null)
                      Text(
                        'Retirée par l’administrateur : '
                        '${offer['moderation_reason']}',
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (_editable(offer))
                IconButton(
                  tooltip: 'Modifier l’offre',
                  icon: const Icon(Icons.edit_outlined),
                  color: AppColors.primary,
                  onPressed: () =>
                      context.push(AppRoutes.editOffer(offer['id'] as int)),
                ),
              if (_slotsEditable(offer) && onEditSlots != null)
                IconButton(
                  tooltip: 'Modifier les créneaux de retrait',
                  icon: const Icon(Icons.edit_calendar_outlined),
                  color: AppColors.primary,
                  onPressed: onEditSlots,
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

/// Risque de gaspillage d'une offre (0 à 100) et suggestions pour l'éviter.
class WasteRisk extends StatelessWidget {
  const WasteRisk({super.key, required this.insight});

  final Json insight;

  @override
  Widget build(BuildContext context) {
    final risk = (insight['risk'] as num?)?.toInt() ?? 0;
    final (label, color) = switch (insight['level']) {
      'high' => ('élevé', AppColors.danger),
      'medium' => ('moyen', AppColors.accent),
      _ => ('faible', AppColors.primary),
    };
    final suggestions = [
      for (final item in insight['suggestions'] as List? ?? const [])
        if (item is String) item,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_outlined, size: 16, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'Risque de gaspillage : $label ($risk/100)',
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          for (final suggestion in suggestions.take(2))
            Text(
              '• $suggestion',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
        ],
      ),
    );
  }
}

/// Conseil personnalisé, rédigé par l'IA à partir des indicateurs (ou par
/// règles si l'IA est indisponible). Demandé à la volée : réseau requis.
class _AdviceCard extends ConsumerStatefulWidget {
  const _AdviceCard();

  @override
  ConsumerState<_AdviceCard> createState() => _AdviceCardState();
}

class _AdviceCardState extends ConsumerState<_AdviceCard> {
  String? _advice;
  String? _source;
  var _loading = false;

  Future<void> _ask() async {
    setState(() => _loading = true);
    try {
      final response = await ref
          .read(dioProvider)
          .post<Map<String, dynamic>>(ApiEndpoints.donorAdvice);
      if (!mounted) return;
      setState(() {
        _advice = response.data?['advice'] as String?;
        _source = response.data?['source'] as String?;
      });
    } on DioException {
      if (mounted) {
        showMessage(
          context,
          'Conseil indisponible hors ligne : les indicateurs ci-dessous '
          'datent de la dernière synchronisation',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.primarySoft,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, color: AppColors.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Conseil pour éviter le gaspillage',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: _loading ? null : _ask,
                  child: _loading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_advice == null ? 'Demander' : 'Actualiser'),
                ),
              ],
            ),
            if (_advice != null) ...[
              const SizedBox(height: 4),
              Text(_advice!),
              const SizedBox(height: 4),
              Text(
                _source == 'ai'
                    ? 'Rédigé par l’IA à partir de vos offres et de votre impact'
                    : 'Calculé à partir de vos offres (IA indisponible)',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
