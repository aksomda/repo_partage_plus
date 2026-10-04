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

    return Scaffold(
      appBar: AppBar(title: const Text("Détail de l'offre")),
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
    final description = offer['description'] as String?;
    final paymentInfo = offer['payment_info'] as String?;
    final phone = offer['contact_phone'] as String?;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              OfferPhoto(
                offer: offer,
                width: double.infinity,
                height: offerPhotoUrl(offer) == null ? 180 : 240,
                iconSize: 80,
              ),
              Padding(
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
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    _Line(
                      Icons.storefront_outlined,
                      '${offer['donor_name'] ?? ''}'
                      '${guestOffer ? ' (sans compte)' : ''}'
                      '${_countryLabel(offer)}',
                    ),
                    if (km != null)
                      _Line(
                        Icons.place_outlined,
                        '${formatDistance(km)} à vol d’oiseau · '
                        '≈ ${formatDistance(estimatedTravelKm(km))} à parcourir, '
                        '${formatWalkingTime(km)}',
                      ),
                    const SizedBox(height: 12),
                    Text(
                      formatPrice(price),
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: price == 0
                            ? AppColors.primary
                            : AppColors.accent,
                      ),
                    ),
                    if (price > 0)
                      Text(
                        'par ${offer['unit'] ?? 'unité'}',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    const SizedBox(height: 12),
                    _Line(
                      Icons.inventory_2_outlined,
                      '${offer['quantity_available']} ${offer['unit']}(s) '
                      'disponible(s)'
                      '${offer['weight_kg'] == null ? '' : ' · ${offer['weight_kg']} kg au total'}',
                    ),
                    _Line(
                      Icons.event_outlined,
                      formatExpiry(offer),
                      color: AppColors.accent,
                    ),
                    _Line(Icons.category_outlined, '${offer['category_name']}'),
                    const _Section('Créneau de retrait'),
                    _Line(Icons.schedule, formatPickup(offer)),
                    _Line(Icons.location_on_outlined, '${offer['address']}'),
                    const SizedBox(height: 8),
                    OsmAndButton(
                      lat: (offer['latitude'] as num).toDouble(),
                      lng: (offer['longitude'] as num).toDouble(),
                      label: '${offer['title']}',
                    ),
                    if (description != null && description.isNotEmpty) ...[
                      const _Section('Description'),
                      Text(description),
                    ],
                    if (price > 0 && paymentInfo != null) ...[
                      const _Section('Paiement (hors application)'),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.accentSoft,
                          borderRadius: BorderRadius.circular(AppTheme.radius),
                        ),
                        child: Text(
                          '$paymentInfo\n\nPayez avant de réserver, puis saisissez '
                          'la référence de la transaction.',
                        ),
                      ),
                    ],
                    if (guestOffer && phone != null) ...[
                      const _Section('Contact du donateur'),
                      _Line(Icons.phone_outlined, phone),
                      const Text(
                        'Publiée sans compte : cette offre ne se réserve pas, '
                        'appelez le donateur pour convenir du retrait.',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (available && !own)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: guestOffer
                    ? FilledButton.icon(
                        onPressed: phone == null
                            ? null
                            : () => _call(context, phone),
                        icon: const Icon(Icons.call),
                        label: const Text('Appeler le donateur'),
                      )
                    : FilledButton(
                        onPressed: () =>
                            context.push(AppRoutes.reserve(offer['id'] as int)),
                        child: const Text('Réserver'),
                      ),
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
  const _Line(this.icon, this.text, {this.color = AppColors.text});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
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
