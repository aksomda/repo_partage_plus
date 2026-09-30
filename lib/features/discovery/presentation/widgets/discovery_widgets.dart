import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Barre de navigation du bas (maquette) : Accueil, Carte, Publier,
/// Réservations, Profil.
class AppBottomNav extends ConsumerWidget {
  const AppBottomNav({super.key, required this.current});

  /// Index de l'onglet affiché (0 à 4).
  final int current;

  static const _routes = [
    AppRoutes.home,
    AppRoutes.nearbyMap,
    AppRoutes.createOffer,
    AppRoutes.myReservations,
    AppRoutes.profile,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(authTokenProvider) != null;
    return NavigationBar(
      selectedIndex: current,
      onDestinationSelected: (index) {
        if (index == current) return;
        // Publier s'ouvre par-dessus ; les autres onglets remplacent l'écran.
        if (index == 2) {
          context.push(_routes[index]);
        } else {
          context.go(_routes[index]);
        }
      },
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Accueil',
        ),
        const NavigationDestination(
          icon: Icon(Icons.map_outlined),
          selectedIcon: Icon(Icons.map),
          label: 'Carte',
        ),
        NavigationDestination(
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: const BoxDecoration(
              color: AppColors.leaf,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add, color: Colors.white),
          ),
          label: 'Publier',
        ),
        const NavigationDestination(
          icon: Icon(Icons.event_note_outlined),
          selectedIcon: Icon(Icons.event_note),
          label: 'Réservations',
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline),
          selectedIcon: const Icon(Icons.person),
          label: loggedIn ? 'Profil' : 'Connexion',
        ),
      ],
    );
  }
}

/// Point de départ des recherches : position actuelle par défaut, ou point
/// choisi. Boutons pour changer de point ou revenir à la position actuelle.
class OriginBar extends ConsumerWidget {
  const OriginBar({super.key});

  Future<void> _useCurrent(BuildContext context, WidgetRef ref) async {
    await ref.read(originProvider.notifier).useCurrentPosition();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final origin = ref.watch(originProvider);
    final place = origin.place;
    final error = origin.error;

    return Material(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  place?.isCurrent ?? false
                      ? Icons.my_location
                      : Icons.place_outlined,
                  color: AppColors.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: 'Autour de : ',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                        TextSpan(
                          text: origin.locating
                              ? 'localisation…'
                              : place?.label ?? 'position inconnue',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (origin.locating)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (!(place?.isCurrent ?? false))
                  IconButton(
                    tooltip: 'Revenir à ma position',
                    icon: const Icon(Icons.my_location),
                    onPressed: () => _useCurrent(context, ref),
                  ),
                TextButton(
                  onPressed: () async {
                    final place = await context.push<Place>(
                      AppRoutes.pickLocation,
                    );
                    if (place != null) {
                      await ref.read(originProvider.notifier).choose(place);
                    }
                  },
                  child: const Text('Changer'),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        error.message,
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (error.canOpenSettings)
                      TextButton(
                        onPressed: ref
                            .read(locationGatewayProvider)
                            .openSettings,
                        child: const Text('Réglages'),
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

/// Rayons de recherche proposés, en km.
const searchRadii = [2.0, 5.0, 10.0, 25.0, 50.0];

/// Filtres de la liste d'offres.
class OfferFilters {
  const OfferFilters({this.text = '', this.categoryId, this.radiusKm = 10});

  final String text;
  final int? categoryId;
  final double radiusKm;

  OfferFilters copyWith({
    String? text,
    int? Function()? categoryId,
    double? radiusKm,
  }) {
    return OfferFilters(
      text: text ?? this.text,
      categoryId: categoryId == null ? this.categoryId : categoryId(),
      radiusKm: radiusKm ?? this.radiusKm,
    );
  }
}

/// Offres disponibles autour du point de départ, filtrées ; sans point de
/// départ connu, toutes les offres (sans distance), par date limite.
List<Json> filterOffers(
  List<Json> offers,
  Place? origin,
  OfferFilters filters,
) {
  final text = filters.text.trim().toLowerCase();
  var result = offers.where((offer) {
    if (filters.categoryId != null &&
        offer['category_id'] != filters.categoryId) {
      return false;
    }
    if (text.isEmpty) return true;
    return [
      offer['title'],
      offer['description'],
      offer['category_name'],
    ].whereType<String>().any((value) => value.toLowerCase().contains(text));
  }).toList();

  if (origin != null) {
    result = nearbyOffers(
      result,
      lat: origin.lat,
      lng: origin.lng,
      radiusKm: filters.radiusKm,
      now: DateTime.now(),
    );
  }
  return result;
}

/// Liste d'offres avec recherche, catégories et rayon (accueil, recherche).
class OffersBrowser extends ConsumerStatefulWidget {
  const OffersBrowser({super.key, this.header, this.autofocusSearch = false});

  /// Contenu affiché au-dessus des filtres (bannière de l'accueil).
  final Widget? header;
  final bool autofocusSearch;

  @override
  ConsumerState<OffersBrowser> createState() => _OffersBrowserState();
}

class _OffersBrowserState extends ConsumerState<OffersBrowser> {
  final _search = TextEditingController();
  var _filters = const OfferFilters();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final origin = ref.watch(originProvider).place;
    final categories = ref.watch(categoriesProvider);
    final offers = filterOffers(
      ref.watch(availableOffersProvider),
      origin,
      _filters,
    );
    final syncing = ref.watch(syncControllerProvider).syncing;

    return RefreshIndicator(
      onRefresh: ref.read(syncControllerProvider.notifier).syncNow,
      child: CustomScrollView(
        slivers: [
          if (widget.header != null) SliverToBoxAdapter(child: widget.header),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _search,
                autofocus: widget.autofocusSearch,
                textInputAction: TextInputAction.search,
                onChanged: (value) =>
                    setState(() => _filters = _filters.copyWith(text: value)),
                decoration: InputDecoration(
                  hintText: 'Rechercher un produit, une catégorie…',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: _filters.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Effacer',
                          onPressed: () {
                            _search.clear();
                            setState(
                              () => _filters = _filters.copyWith(text: ''),
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _chip(
                    'Tous',
                    _filters.categoryId == null,
                    () => _filters.copyWith(categoryId: () => null),
                  ),
                  for (final category in categories)
                    _chip(
                      category['name'] as String,
                      _filters.categoryId == category['id'],
                      () => _filters.copyWith(
                        categoryId: () => category['id'] as int,
                      ),
                      icon: categoryIcon(category['icon']),
                    ),
                ],
              ),
            ),
          ),
          if (origin != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.radar,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Rayon',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    Expanded(
                      child: Slider(
                        value: searchRadii
                            .indexOf(_filters.radiusKm)
                            .toDouble(),
                        max: (searchRadii.length - 1).toDouble(),
                        divisions: searchRadii.length - 1,
                        label: '${_filters.radiusKm.round()} km',
                        onChanged: (value) => setState(
                          () => _filters = _filters.copyWith(
                            radiusKm: searchRadii[value.round()],
                          ),
                        ),
                      ),
                    ),
                    Text(
                      '${_filters.radiusKm.round()} km',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                origin == null
                    ? 'Offres disponibles (${offers.length})'
                    : 'Offres à proximité (${offers.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          if (offers.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: syncing
                  ? const Center(child: CircularProgressIndicator())
                  : EmptyState(
                      icon: Icons.search_off,
                      title: 'Aucune offre trouvée',
                      message: origin == null
                          ? 'Tirez vers le bas pour actualiser.'
                          : 'Élargissez le rayon, changez de point de départ '
                                'ou de catégorie.',
                    ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverList.separated(
                itemCount: offers.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => OfferCard(
                  offer: offers[index],
                  onTap: () =>
                      context.push(AppRoutes.offer('${offers[index]['id']}')),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    String label,
    bool selected,
    OfferFilters Function() apply, {
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: icon == null
            ? null
            : Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : AppColors.primary,
              ),
        label: Text(label),
        selected: selected,
        labelStyle: TextStyle(color: selected ? Colors.white : AppColors.text),
        onSelected: (_) => setState(() => _filters = apply()),
      ),
    );
  }
}
