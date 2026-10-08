import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/profile_avatar.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';
import 'package:repo_partage_plus/features/notifications/presentation/widgets/chat_view.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/reservations/data/reservations_repository.dart';

/// Messages de l'utilisateur : l'équipe Partage+, puis ses échanges avec
/// les publieurs (commerçants, restaurateurs, associations…) ou les
/// bénéficiaires de ses offres.
class MessagesScreen extends ConsumerWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(directConversationsProvider);
    final teamUnread = ref.watch(unreadTeamMessagesCountProvider);
    final teamLast = ref.watch(userMessagesFeedProvider).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: RefreshIndicator(
        onRefresh: ref.read(syncControllerProvider.notifier).syncNow,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _ConversationTile(
              leading: const CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.primarySoft,
                child: Icon(Icons.support_agent, color: AppColors.primary),
              ),
              title: 'Équipe Partage+',
              subtitle: teamLast == null
                  ? 'Une question, un souci de retrait ? Écrivez-nous.'
                  : _preview(teamLast.body, teamLast.photosCount),
              time: teamLast?.at,
              unread: teamUnread,
              onTap: () => context.push(AppRoutes.teamMessages),
            ),
            const SizedBox(height: 16),
            const Text(
              'Publieurs et bénéficiaires',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 8),
            if (conversations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Aucun échange pour l’instant.\nSur la fiche d’une offre, '
                  'touchez « Écrire » pour contacter son publieur.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted),
                ),
              )
            else
              for (final c in conversations) ...[
                _ConversationTile(
                  leading: ProfileAvatar(name: c.name, size: 44),
                  title: c.name,
                  badge: c.actor,
                  context: c.offerTitle,
                  subtitle: _preview(
                    c.last['body'] as String?,
                    (c.last['photos_count'] as num?)?.toInt() ?? 0,
                  ),
                  time: DateTime.tryParse('${c.last['created_at']}')?.toLocal(),
                  unread: c.unread,
                  onTap: () => context.push(
                    AppRoutes.directConversation(c.peerId, offerId: c.offerId),
                  ),
                ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }
}

String _preview(String? body, int photos) => body != null && body.isNotEmpty
    ? body
    : photos > 0
    ? '📷 Image'
    : '';

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.unread,
    required this.onTap,
    this.time,
    this.badge,
    this.context,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final int unread;
  final VoidCallback onTap;
  final DateTime? time;

  /// Acteur du correspondant (Commerçant, Association…).
  final String? badge;

  /// Offre dont on parle.
  final String? context;

  @override
  Widget build(BuildContext context) {
    final at = time;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: unread > 0
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: const ShapeDecoration(
                              color: AppColors.accentSoft,
                              shape: StadiumBorder(),
                            ),
                            child: Text(
                              badge!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF9A641B),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (this.context != null)
                      Text(
                        'À propos de « ${this.context} »',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.primary,
                        ),
                      ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (at != null)
                    Text(
                      DateUtils.isSameDay(at, DateTime.now())
                          ? formatHour(at)
                          : formatDay(at),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                  if (unread > 0) ...[
                    const SizedBox(height: 4),
                    Badge(label: Text('$unread')),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Échanges de l'utilisateur avec l'équipe Partage+ (mini chat).
class TeamMessagesScreen extends StatelessWidget {
  const TeamMessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Équipe Partage+')),
      body: const ChatView(messagesOnly: true),
    );
  }
}

/// Échange avec un autre utilisateur ; [offerId] : offre dont on parle
/// (ouvert depuis la fiche détail ou une réservation reçue).
class DirectConversationScreen extends ConsumerWidget {
  const DirectConversationScreen({
    super.key,
    required this.peerId,
    this.offerId,
  });

  final int peerId;
  final int? offerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversation = ref
        .watch(directConversationsProvider)
        .where((c) => c.peerId == peerId)
        .firstOrNull;
    final offers = [
      ...ref.watch(availableOffersProvider),
      ...ref.watch(myOffersProvider),
    ];
    final offerId = this.offerId ?? conversation?.offerId;
    final offer = offers.where((o) => o['id'] == offerId).firstOrNull;
    // Nom : échange déjà commencé, sinon publieur de l'offre, sinon
    // bénéficiaire d'une réservation reçue.
    final name =
        conversation?.name ??
        offers
            .where((o) => o['donor_id'] == peerId)
            .map((o) => o['donor_name'] as String?)
            .nonNulls
            .firstOrNull ??
        ref
            .watch(receivedReservationsProvider)
            .where((r) => r['beneficiary_id'] == peerId)
            .map((r) => r['beneficiary_name'] as String?)
            .nonNulls
            .firstOrNull;
    final offerTitle = offer?['title'] as String? ?? conversation?.offerTitle;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ProfileAvatar(name: name ?? '?', size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name ?? 'Conversation', overflow: TextOverflow.ellipsis),
                  if (conversation?.actor case final actor?)
                    Text(
                      actor,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (offerTitle != null)
            Material(
              color: AppColors.primarySoft,
              child: InkWell(
                onTap: offerId == null
                    ? null
                    : () => context.push(AppRoutes.offer('$offerId')),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      if (offer != null) ...[
                        OfferThumbnail(offer: offer, size: 36),
                        const SizedBox(width: 10),
                      ] else ...[
                        const Icon(
                          Icons.inventory_2_outlined,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          'À propos de « $offerTitle »',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (offerId != null)
                        const Icon(
                          Icons.chevron_right,
                          color: AppColors.primary,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: ChatView(peerId: peerId, offerId: this.offerId),
          ),
        ],
      ),
    );
  }
}

/// Bouton « Écrire » vers un autre utilisateur (fiche détail, réservation
/// reçue) ; sans compte, l'écran de connexion s'ouvre d'abord.
class WriteToButton extends StatelessWidget {
  const WriteToButton({
    super.key,
    required this.peerId,
    this.offerId,
    this.label,
    this.tooltip = 'Écrire au publieur',
  });

  final int peerId;
  final int? offerId;

  /// Avec un libellé : bouton « Écrire » ; sinon icône seule.
  final String? label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    void open() =>
        context.push(AppRoutes.directConversation(peerId, offerId: offerId));
    final label = this.label;
    if (label == null) {
      return IconButton.outlined(
        tooltip: tooltip,
        style: IconButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.primary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          minimumSize: const Size(52, 52),
        ),
        onPressed: open,
        icon: const Icon(Icons.chat_bubble_outline),
      );
    }
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: open,
        icon: const Icon(Icons.chat_bubble_outline),
        label: Text(label),
      ),
    );
  }
}
