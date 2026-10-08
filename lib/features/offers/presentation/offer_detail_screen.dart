import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:repo_partage_plus/core/countries/countries.dart';
import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/location/geo.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/maps/osmand_button.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/favorites/presentation/favorite_button.dart';
import 'package:repo_partage_plus/features/notifications/presentation/messages_screen.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';
import 'package:repo_partage_plus/features/recommendations/data/preferences.dart';

/// Détail d'une offre, consultable sans compte.
class OfferDetailScreen extends ConsumerWidget {
  const OfferDetailScreen({super.key, required this.offerId});

  final String offerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = int.tryParse(offerId);
    final offer = id == null
        ? const AsyncValue<Json>.error('Offre introuvable', StackTrace.empty)
        : ref.watch(offerDetailProvider(id));

    final loaded = offer.hasValue && !offer.hasError;
    return Scaffold(
      // Offre chargée : la photo sert d'en-tête (boutons posés dessus).
      appBar: loaded ? null : AppBar(title: const Text("Détail de l'offre")),
      body: offer.when(
        data: (data) => _Details(offer: data),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: EmptyState(
            icon: Icons.search_off,
            title: 'Offre indisponible',
            message: '$error',
            action: OutlinedButton(
              onPressed: () => context.go(AppRoutes.home),
              child: const Text('Voir les offres'),
            ),
          ),
        ),
      ),
    );
  }
}

class _Details extends ConsumerStatefulWidget {
  const _Details({required this.offer});

  final Json offer;

  @override
  ConsumerState<_Details> createState() => _DetailsState();
}

class _DetailsState extends ConsumerState<_Details> {
  Json get offer => widget.offer;

  @override
  void initState() {
    super.initState();
    // Historique local d'interactions, utilisé par les recommandations.
    recordOfferView(ref.read(localStoreProvider), offer);
  }

  @override
  Widget build(BuildContext context) {
    final origin = ref.watch(originProvider).place;
    final profile = ref.watch(profileProvider);
    final price = offer['price'] as num? ?? 0;
    final available = isOfferAvailable(offer, DateTime.now());
    final guestOffer = isGuestOffer(offer);
    // Publiée par ce compte, ou sans compte depuis cet appareil.
    final own = guestOffer
        ? (ref.watch(guestOffersProvider).value ?? const []).any(
            (item) => item['id'] == offer['id'],
          )
        : profile != null && profile['id'] == offer['donor_id'];

    final km = origin == null
        ? null
        : haversineKm(
            origin.lat,
            origin.lng,
            (offer['latitude'] as num).toDouble(),
            (offer['longitude'] as num).toDouble(),
          );
    // Publieur avec compte : on peut lui écrire (sauf l'administration,
    // qui a son propre mini chat).
    final donorId = (offer['donor_id'] as num?)?.toInt() ?? 0;
    final canWrite = !guestOffer && donorId > 0 && profile?['role'] != 'admin';
    final description = offer['description'] as String?;
    final paymentInfo = offer['payment_info'] as String?;
    final phone = offer['contact_phone'] as String?;

    final weight = offer['weight_kg'] as num?;
    final hasPhoto = offerPhotoUrl(offer) != null;

    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: hasPhoto ? 280 : 220,
                backgroundColor: AppColors.surface,
                // Titre lu par les lecteurs d'écran ; la photo le remplace.
                title: const Text(
                  "Détail de l'offre",
                  style: TextStyle(color: Colors.transparent),
                ),
                leading: Navigator.of(context).canPop()
                    ? const Padding(
                        padding: EdgeInsets.all(6),
                        child: _RoundButton(child: BackButton()),
                      )
                    : null,
                actions: [
                  if (offer['id'] case final int id)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: FavoriteButton(offerId: id, filled: true),
                    ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: OfferPhoto(
                    offer: offer,
                    width: double.infinity,
                    height: double.infinity,
                    iconSize: 88,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (offer['status'] != 'published')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: StatusBadge(offer['status'] as String),
                        ),
                      Text(
                        offer['title'] as String,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      _Line(
                        Icons.storefront_outlined,
                        '${offer['donor_name'] ?? ''}'
                        '${guestOffer ? ' (sans compte)' : ''}'
                        '${_countryLabel(offer)}',
                        iconColor: AppColors.primary,
                      ),
                      if (km != null)
                        _Line(
                          Icons.place_outlined,
                          '${formatDistance(km)} à vol d’oiseau · '
                          '≈ ${formatDistance(estimatedTravelKm(km))} à '
                          'parcourir, ${formatWalkingTime(km)}',
                          iconColor: AppColors.primary,
                        ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            price == 0 ? 'Don gratuit' : formatPrice(price),
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: price == 0
                                  ? AppColors.primary
                                  : AppColors.accent,
                            ),
                          ),
                          if (price > 0)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 6,
                                bottom: 3,
                              ),
                              child: Text(
                                'par ${offer['unit'] ?? 'unité'}',
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _Pill(
                            Icons.inventory_2_outlined,
                            '${offer['quantity_available']} ${offer['unit']}(s) '
                            'disponible(s)',
                          ),
                          if (weight != null && weight > 0)
                            _Pill(
                              Icons.scale_outlined,
                              '${formatNumber(weight, decimals: 1)} kg au total',
                            ),
                          _Pill(
                            Icons.event_outlined,
                            formatExpiry(offer),
                            color: AppColors.accent,
                          ),
                        ],
                      ),
                      if (description != null && description.isNotEmpty) ...[
                        const _Section('Description'),
                        Text(description),
                      ],
                      const SizedBox(height: 8),
                      _Line(
                        Icons.category_outlined,
                        'Catégorie : ${offer['category_name']}',
                      ),
                      if (offerSlots(offer) case final slots
                          when slots.length > 1) ...[
                        _Section('Créneaux de retrait (${slots.length})'),
                        for (final slot in slots)
                          _Line(
                            Icons.schedule,
                            formatPeriod(slot.start, slot.end),
                          ),
                      ] else ...[
                        const _Section('Créneau de retrait'),
                        _Line(Icons.schedule, formatPickup(offer)),
                      ],
                      _Line(Icons.location_on_outlined, '${offer['address']}'),
                      const SizedBox(height: 8),
                      OsmAndButton(
                        lat: (offer['latitude'] as num).toDouble(),
                        lng: (offer['longitude'] as num).toDouble(),
                        label: '${offer['title']}',
                      ),
                      if (price > 0 && paymentInfo != null) ...[
                        const _Section('Paiement (hors application)'),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.accentSoft,
                            borderRadius: BorderRadius.circular(
                              AppTheme.radius,
                            ),
                          ),
                          child: Text(
                            '$paymentInfo\n\nPayez avant de réserver, puis '
                            'saisissez la référence de la transaction.',
                          ),
                        ),
                      ],
                      if (guestOffer && phone != null) ...[
                        const _Section('Contact du donateur'),
                        _Line(Icons.phone_outlined, phone),
                        const Text(
                          'Publiée sans compte : cette offre ne se réserve '
                          'pas, appelez le donateur pour convenir du retrait.',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!own && (available || canWrite))
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  if (available)
                    Expanded(
                      child: guestOffer
                          ? FilledButton.icon(
                              onPressed: phone == null
                                  ? null
                                  : () => _call(context, phone),
                              icon: const Icon(Icons.call),
                              label: const Text('Appeler le donateur'),
                            )
                          : FilledButton(
                              onPressed: () => context.push(
                                AppRoutes.reserve(offer['id'] as int),
                              ),
                              child: const Text('Réserver'),
                            ),
                    ),
                  if (canWrite) ...[
                    if (available) const SizedBox(width: 12),
                    if (available)
                      WriteToButton(
                        peerId: donorId,
                        offerId: offer['id'] as int,
                      )
                    else
                      Expanded(
                        child: WriteToButton(
                          peerId: donorId,
                          offerId: offer['id'] as int,
                          label: 'Écrire au publieur',
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Ouvre le composeur téléphonique sur le numéro du donateur.
Future<void> _call(BuildContext context, String phone) async {
  final uri = Uri(scheme: 'tel', path: phone.replaceAll(' ', ''));
  final launched = await launchUrl(uri).catchError((_) => false);
  if (!launched && context.mounted) {
    showMessage(context, 'Appel impossible : composez le $phone', error: true);
  }
}

/// « · 🇧🇫 Burkina Faso » : pays du publieur, s'il est connu.
String _countryLabel(Json offer) {
  final name = offer['country_name'] as String?;
  if (name == null) return '';
  final flag = countryByCode(offer['country_code'] as String?)?.flag;
  return ' · ${flag == null ? '' : '$flag '}$name';
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text, {this.iconColor = AppColors.textMuted});

  final IconData icon;
  final String text;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    );
  }
}

/// Information courte en pastille (quantité, poids, date limite).
class _Pill extends StatelessWidget {
  const _Pill(this.icon, this.text, {this.color = AppColors.text});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: color == AppColors.text ? AppColors.textMuted : color,
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pastille blanche ronde sous un bouton posé sur la photo.
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 1,
      child: child,
    );
  }
}
