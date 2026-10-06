import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:repo_partage_plus/core/guest/guest_repository.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/text_prompt_dialog.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/favorites/data/favorites.dart';
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
          tooltip: 'Les offres disponibles autour de votre point de départ',
        ),
        const NavigationDestination(
          icon: Icon(Icons.map_outlined),
          selectedIcon: Icon(Icons.map),
          label: 'Carte',
          tooltip: 'Les offres à proximité, sur la carte',
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
          tooltip: 'Donner ou vendre à prix réduit vos invendus et surplus',
        ),
        const NavigationDestination(
          icon: Icon(Icons.event_note_outlined),
          selectedIcon: Icon(Icons.event_note),
          label: 'Réservations',
          tooltip: 'Vos réservations et leur code de retrait',
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline),
          selectedIcon: const Icon(Icons.person),
          label: loggedIn ? 'Profil' : 'Connexion',
          tooltip: loggedIn
              ? 'Vos informations, votre mot de passe et vos préférences'
              : 'Accéder à votre compte ou en créer un',
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

/// Pas de limite de distance : toutes les offres, triées par distance.
const unlimitedRadius = double.infinity;

/// Rayons de recherche proposés, en km ; le dernier : illimité (par défaut).
const searchRadii = [2.0, 5.0, 10.0, 25.0, 50.0, 100.0, 250.0, unlimitedRadius];

/// « 10 km », ou « Illimité ».
String radiusLabel(double km) => km.isFinite ? '${km.round()} km' : 'Illimité';

/// Auteur des offres affichées.
enum OfferOwner { all, mine, others }

/// Ordre de la liste d'offres.
enum OfferSort {
  nearest('Les plus proches'),
  expiry('Date limite la plus proche'),
  price('Prix croissant');

  const OfferSort(this.label);

  final String label;

  static OfferSort fromName(Object? name) =>
      values.where((value) => value.name == name).firstOrNull ?? nearest;
}

/// Filtres de la liste d'offres.
class OfferFilters {
  const OfferFilters({
    this.text = '',
    this.categoryId,
    this.radiusKm = unlimitedRadius,
    this.owner = OfferOwner.all,
    this.favoritesOnly = false,
    this.price = PriceFilter.all,
    this.urgentOnly = false,
    this.sort = OfferSort.nearest,
  });

  final String text;
  final int? categoryId;
  final double radiusKm;
  final OfferOwner owner;

  /// Seulement les offres mises en favori.
  final bool favoritesOnly;

  /// Gratuit, prix réduit, ou les deux.
  final PriceFilter price;

  /// Seulement les offres dont la date limite est aujourd'hui ou demain.
  final bool urgentOnly;

  final OfferSort sort;

  /// Critères qui méritent d'être enregistrés comme recherche favorite.
  bool get isSearch =>
      text.trim().isNotEmpty ||
      categoryId != null ||
      price != PriceFilter.all ||
      urgentOnly;

  /// Un filtre autre que le texte et la catégorie est actif.
  bool get hasRefinements =>
      price != PriceFilter.all || urgentOnly || sort != OfferSort.nearest;

  OfferFilters copyWith({
    String? text,
    int? Function()? categoryId,
    double? radiusKm,
    OfferOwner? owner,
    bool? favoritesOnly,
    PriceFilter? price,
    bool? urgentOnly,
    OfferSort? sort,
  }) {
    return OfferFilters(
      text: text ?? this.text,
      categoryId: categoryId == null ? this.categoryId : categoryId(),
      radiusKm: radiusKm ?? this.radiusKm,
      owner: owner ?? this.owner,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      price: price ?? this.price,
      urgentOnly: urgentOnly ?? this.urgentOnly,
      sort: sort ?? this.sort,
    );
  }

  /// Applique une recherche enregistrée (ou suggérée).
  OfferFilters withSearch(SavedSearch search) => copyWith(
    text: search.text,
    categoryId: () => search.categoryId,
    radiusKm: nearestRadius(search.radiusKm),
    price: search.price,
    urgentOnly: search.urgentOnly,
  );

  /// Mémorisés sur l'appareil, sauf le texte saisi.
  Map<String, Object?> toMap() => {
    'category_id': categoryId,
    // Clé renommée : l'ancien rayon (10 km par défaut) n'est pas repris.
    'search_radius_km': radiusKm.isFinite ? radiusKm : null,
    'owner': owner.name,
    'favorites_only': favoritesOnly,
    'price': price.name,
    'urgent_only': urgentOnly,
    'sort': sort.name,
  };

  static OfferFilters fromMap(Object? value) {
    if (value is! Map) return const OfferFilters();
    return OfferFilters(
      categoryId: (value['category_id'] as num?)?.toInt(),
      radiusKm: nearestRadius(
        (value['search_radius_km'] as num?)?.toDouble() ?? unlimitedRadius,
      ),
      owner:
          OfferOwner.values
              .where((owner) => owner.name == value['owner'])
              .firstOrNull ??
          OfferOwner.all,
      favoritesOnly: value['favorites_only'] == true,
      price: PriceFilter.fromName(value['price']),
      urgentOnly: value['urgent_only'] == true,
      sort: OfferSort.fromName(value['sort']),
    );
  }
}

/// Rayon proposé le plus proche de [km].
double nearestRadius(double km) => km.isFinite
    ? searchRadii.reduce(
        (best, radius) =>
            (radius - km).abs() < (best - km).abs() ? radius : best,
      )
    : unlimitedRadius;

/// Applique le filtre d'auteur puis [filterOffers].
///
/// [mine] : offres de l'utilisateur (compte et invité), tous statuts
/// (terminées et retirées comprises) ; affichées sans contrainte de rayon.
List<Json> filterOffersByOwner({
  required List<Json> available,
  required List<Json> mine,
  required Place? origin,
  required OfferFilters filters,
  Set<int> favoriteIds = const {},
}) {
  if (filters.favoritesOnly) {
    available = [
      for (final offer in available)
        if (favoriteIds.contains(offer['id'])) offer,
    ];
    mine = [
      for (final offer in mine)
        if (favoriteIds.contains(offer['id'])) offer,
    ];
  }
  switch (filters.owner) {
    case OfferOwner.all:
      return filterOffers(available, origin, filters);
    case OfferOwner.mine:
      return filterOffers(mine, null, filters);
    case OfferOwner.others:
      final mineIds = {for (final offer in mine) offer['id']}..remove(null);
      return filterOffers(
        available.where((offer) => !mineIds.contains(offer['id'])).toList(),
        origin,
        filters,
      );
  }
}

/// Offres disponibles autour du point de départ, filtrées puis triées ;
/// sans point de départ connu, toutes les offres (sans distance).
List<Json> filterOffers(
  List<Json> offers,
  Place? origin,
  OfferFilters filters, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  var result = offers.where((offer) {
    if (filters.categoryId != null &&
        offer['category_id'] != filters.categoryId) {
      return false;
    }
    if (!filters.price.accepts(offer)) return false;
    if (filters.urgentOnly && !expiresSoon(offer, at)) return false;
    return matchesText(offer, filters.text);
  }).toList();

  if (origin != null) {
    // Triées par distance.
    result = nearbyOffers(
      result,
      lat: origin.lat,
      lng: origin.lng,
      radiusKm: filters.radiusKm,
      now: at,
    );
  }

  switch (filters.sort) {
    case OfferSort.nearest:
      break;
    case OfferSort.expiry:
      // Tri stable : à date égale, la plus proche d'abord.
      result = _stableSorted(
        result,
        (a, b) => '${a['expiry_date']}'.compareTo('${b['expiry_date']}'),
      );
    case OfferSort.price:
      result = _stableSorted(
        result,
        (a, b) => (a['price'] as num? ?? 0).compareTo(b['price'] as num? ?? 0),
      );
  }
  return result;
}

/// Trié par [compare] ; à égalité, l'ordre d'origine (la distance) est gardé.
List<Json> _stableSorted(List<Json> offers, Comparator<Json> compare) {
  final indexed = offers.indexed.toList()
    ..sort((a, b) {
      final order = compare(a.$2, b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  return [for (final (_, offer) in indexed) offer];
}

/// Filtres des offres, partagés par la liste (accueil, recherche) et la
/// carte, et mémorisés sur l'appareil (sauf le texte saisi).
class OfferFiltersController extends Notifier<OfferFilters> {
  static const _key = 'offer_filters';

  @override
  OfferFilters build() {
    Future.microtask(() async {
      final saved = await ref
          .read(localStoreProvider)
          .readSetting<Object?>(_key);
      if (saved != null) {
        state = OfferFilters.fromMap(saved).copyWith(text: state.text);
      }
    });
    return const OfferFilters();
  }

  void apply(OfferFilters filters) {
    final remembered = filters.toMap().toString() != state.toMap().toString();
    state = filters;
    if (remembered) {
      ref.read(localStoreProvider).saveSetting(_key, filters.toMap());
    }
  }

  void reset() => apply(const OfferFilters());
}

final offerFiltersProvider =
    NotifierProvider<OfferFiltersController, OfferFilters>(
      OfferFiltersController.new,
    );

/// Liste d'offres avec recherche, catégories, rayon, prix, urgence et tri
/// (accueil, recherche). Les filtres sont mémorisés sur l'appareil.
class OffersBrowser extends ConsumerStatefulWidget {
  const OffersBrowser({super.key, this.header, this.autofocusSearch = false});

  /// Contenu affiché au-dessus des filtres (bannière de l'accueil).
  final Widget? header;
  final bool autofocusSearch;

  @override
  ConsumerState<OffersBrowser> createState() => _OffersBrowserState();
}

class _OffersBrowserState extends ConsumerState<OffersBrowser> {
  late final _search = TextEditingController(
    text: ref.read(offerFiltersProvider).text,
  );

  OfferFilters get _filters => ref.read(offerFiltersProvider);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _apply(OfferFilters filters) {
    if (_search.text != filters.text) _search.text = filters.text;
    ref.read(offerFiltersProvider.notifier).apply(filters);
  }

  void _reset() => _apply(const OfferFilters());

  @override
  Widget build(BuildContext context) {
    ref.watch(offerFiltersProvider);
    final origin = ref.watch(originProvider).place;
    final loggedIn = ref.watch(authTokenProvider) != null;
    final mine = <Json>[
      if (loggedIn) ...ref.watch(myOffersProvider),
      ...?ref.watch(guestOffersProvider).value,
    ];
    final available = ref.watch(availableOffersProvider);
    final favorites = ref.watch(favoritesProvider);
    final offers = filterOffersByOwner(
      available: available,
      mine: mine,
      origin: origin,
      filters: _filters,
      favoriteIds: favorites.offerIds,
    );
    final showMine = _filters.owner == OfferOwner.mine;
    final syncing = ref.watch(syncControllerProvider).syncing;

    // Favoris réservés, retirés ou expirés : plus dans la liste disponible.
    final visibleIds = {
      for (final offer in [...available, ...mine]) offer['id'],
    };
    final missingFavorites = favorites.offerIds
        .where((id) => !visibleIds.contains(id))
        .length;

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
                onChanged: (value) => ref
                    .read(offerFiltersProvider.notifier)
                    .apply(_filters.copyWith(text: value)),
                decoration: InputDecoration(
                  hintText: 'Rechercher un produit, une catégorie…',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: _filters.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Effacer',
                          onPressed: () => _apply(_filters.copyWith(text: '')),
                        ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: CategoryFilterChips(filters: _filters, onApply: _apply),
          ),
          SliverToBoxAdapter(
            child: RefineFilterBar(
              filters: _filters,
              onApply: _apply,
              onReset: _reset,
              hasOrigin: origin != null,
            ),
          ),
          SliverToBoxAdapter(
            child: _FavoritesBar(
              favorites: favorites,
              filters: _filters,
              onApply: (filters) {
                _search.text = filters.text;
                _apply(filters);
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: SegmentedButton<OfferOwner>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: OfferOwner.all,
                    label: Text('Toutes'),
                    icon: Icon(Icons.storefront_outlined),
                  ),
                  ButtonSegment(
                    value: OfferOwner.mine,
                    label: Text('Mes offres'),
                    icon: Icon(Icons.person_outline),
                  ),
                  ButtonSegment(
                    value: OfferOwner.others,
                    label: Text('Des autres'),
                    icon: Icon(Icons.groups_outlined),
                  ),
                ],
                selected: {_filters.owner},
                onSelectionChanged: (selection) =>
                    _apply(_filters.copyWith(owner: selection.first)),
              ),
            ),
          ),
          // Mes offres : toutes affichées, quel que soit le rayon.
          if (origin != null && !showMine)
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
                        label: radiusLabel(_filters.radiusKm),
                        onChanged: (value) => _apply(
                          _filters.copyWith(
                            radiusKm: searchRadii[value.round()],
                          ),
                        ),
                      ),
                    ),
                    Text(
                      radiusLabel(_filters.radiusKm),
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
                showMine
                    ? 'Mes offres (${offers.length})'
                    : origin == null
                    ? 'Offres disponibles (${offers.length})'
                    : 'Offres à proximité (${offers.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          if (_filters.favoritesOnly && missingFavorites > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        missingFavorites == 1
                            ? '1 favori n’est plus disponible (réservé, '
                                  'retiré ou expiré).'
                            : '$missingFavorites favoris ne sont plus '
                                  'disponibles (réservés, retirés ou expirés).',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (offers.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: syncing
                  ? const Center(child: CircularProgressIndicator())
                  : showMine
                  ? const EmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: 'Aucune offre publiée',
                      message:
                          'Vos offres apparaîtront ici, y compris celles '
                          'terminées ou retirées.',
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        EmptyState(
                          icon: Icons.search_off,
                          title: 'Aucune offre trouvée',
                          message: origin == null
                              ? 'Tirez vers le bas pour actualiser.'
                              : 'Élargissez le rayon, changez de point de '
                                    'départ ou de catégorie.',
                        ),
                        if (_filters.isSearch ||
                            _filters.hasRefinements ||
                            _filters.favoritesOnly)
                          TextButton.icon(
                            onPressed: _reset,
                            icon: const Icon(Icons.filter_alt_off_outlined),
                            label: const Text('Effacer les filtres'),
                          ),
                      ],
                    ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverList.separated(
                itemCount: offers.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final offer = offers[index];
                  return OfferCard(
                    offer: offer,
                    showStatus: showMine,
                    // Offre pas encore envoyée (hors ligne) : sans id serveur.
                    onTap: () => offer['id'] == null || offer['local'] == true
                        ? context.push(AppRoutes.myOffers)
                        : context.push(AppRoutes.offer('${offer['id']}')),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Catégories : « Tous » puis une puce par catégorie.
class CategoryFilterChips extends ConsumerWidget {
  const CategoryFilterChips({
    super.key,
    required this.filters,
    required this.onApply,
  });

  final OfferFilters filters;
  final ValueChanged<OfferFilters> onApply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip(
            'Tous',
            filters.categoryId == null,
            () => filters.copyWith(categoryId: () => null),
          ),
          for (final category in categories)
            _chip(
              category['name'] as String,
              filters.categoryId == category['id'],
              () => filters.copyWith(categoryId: () => category['id'] as int),
              icon: categoryIcon(category['icon']),
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
        onSelected: (_) => onApply(apply()),
      ),
    );
  }
}

/// Prix (gratuit / prix réduit), urgence et tri ; sur la carte ([onMap]),
/// aussi le texte cherché et le rayon.
class RefineFilterBar extends StatelessWidget {
  const RefineFilterBar({
    super.key,
    required this.filters,
    required this.onApply,
    required this.onReset,
    required this.hasOrigin,
    this.onMap = false,
  });

  final OfferFilters filters;
  final ValueChanged<OfferFilters> onApply;
  final VoidCallback onReset;
  final bool hasOrigin;
  final bool onMap;

  @override
  Widget build(BuildContext context) {
    Widget toggle(
      String label,
      IconData icon,
      bool selected,
      OfferFilters Function(bool) apply,
    ) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          avatar: Icon(icon, size: 18),
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          onSelected: (on) => onApply(apply(on)),
        ),
      );
    }

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          if (onMap && filters.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InputChip(
                avatar: const Icon(Icons.search, size: 18),
                label: Text('« ${filters.text.trim()} »'),
                deleteButtonTooltipMessage: 'Retirer',
                onDeleted: () => onApply(filters.copyWith(text: '')),
              ),
            ),
          if (onMap && hasOrigin)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: PopupMenuButton<double>(
                tooltip: 'Rayon',
                initialValue: filters.radiusKm,
                onSelected: (radius) =>
                    onApply(filters.copyWith(radiusKm: radius)),
                itemBuilder: (_) => [
                  for (final radius in searchRadii)
                    PopupMenuItem(
                      value: radius,
                      child: Text(radiusLabel(radius)),
                    ),
                ],
                child: Chip(
                  avatar: const Icon(Icons.radar, size: 18),
                  label: Text('Rayon : ${radiusLabel(filters.radiusKm)}'),
                ),
              ),
            ),
          if (!onMap)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: PopupMenuButton<OfferSort>(
                tooltip: 'Trier',
                initialValue: filters.sort,
                onSelected: (sort) => onApply(filters.copyWith(sort: sort)),
                itemBuilder: (_) => [
                  for (final sort in OfferSort.values)
                    PopupMenuItem(
                      value: sort,
                      enabled: sort != OfferSort.nearest || hasOrigin,
                      child: Text(sort.label),
                    ),
                ],
                child: Chip(
                  avatar: const Icon(Icons.sort, size: 18),
                  label: Text('Tri : ${filters.sort.label.toLowerCase()}'),
                ),
              ),
            ),
          toggle(
            PriceFilter.free.label,
            Icons.volunteer_activism_outlined,
            filters.price == PriceFilter.free,
            (on) => filters.copyWith(
              price: on ? PriceFilter.free : PriceFilter.all,
            ),
          ),
          toggle(
            PriceFilter.paid.label,
            Icons.sell_outlined,
            filters.price == PriceFilter.paid,
            (on) => filters.copyWith(
              price: on ? PriceFilter.paid : PriceFilter.all,
            ),
          ),
          toggle(
            'À sauver vite',
            Icons.timer_outlined,
            filters.urgentOnly,
            (on) => filters.copyWith(urgentOnly: on),
          ),
          if (filters.isSearch || filters.hasRefinements)
            ActionChip(
              avatar: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('Effacer'),
              onPressed: onReset,
            ),
        ],
      ),
    );
  }
}

/// Favoris (sans compte aussi) : filtre « offres favorites », recherches
/// enregistrées (relancées d'un geste, supprimables par leur croix),
/// recherches suggérées, et enregistrement de la recherche en cours.
class _FavoritesBar extends ConsumerWidget {
  const _FavoritesBar({
    required this.favorites,
    required this.filters,
    required this.onApply,
  });

  final Favorites favorites;
  final OfferFilters filters;
  final ValueChanged<OfferFilters> onApply;

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final categories = ref.read(categoriesProvider);
    final category = categories
        .where((c) => c['id'] == filters.categoryId)
        .firstOrNull;
    final suggested = [
      if (filters.text.trim().isNotEmpty) filters.text.trim(),
      if (category != null) category['name'],
      if (filters.price != PriceFilter.all) filters.price.label,
      if (filters.urgentOnly) 'urgent',
    ].join(' · ');
    final name = await _askName(context, suggested);
    if (name == null) return;
    await ref
        .read(favoritesProvider.notifier)
        .saveSearch(
          SavedSearch(
            name: name,
            text: filters.text.trim(),
            categoryId: filters.categoryId,
            radiusKm: filters.radiusKm,
            price: filters.price,
            urgentOnly: filters.urgentOnly,
          ),
        );
    if (context.mounted) {
      showMessage(
        context,
        'Recherche « $name » enregistrée : vous serez prévenu des nouvelles '
        'offres correspondantes',
      );
    }
  }

  Future<String?> _askName(BuildContext context, String suggested) {
    return showTextPrompt(
      context,
      title: 'Enregistrer la recherche',
      action: 'Enregistrer',
      hint: 'Nom (ex. : Pain du soir)',
      initial: suggested,
      maxLength: 40,
      emptyMessage: 'Donnez un nom à la recherche',
    );
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    SavedSearch search,
  ) async {
    final notifier = ref.read(favoritesProvider.notifier);
    await notifier.removeSearch(search.name);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Recherche « ${search.name} » supprimée'),
          action: SnackBarAction(
            label: 'Annuler',
            onPressed: () => notifier.saveSearch(search),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = favorites.offerIds.length;
    final saved = {
      for (final search in favorites.searches) search.name.toLowerCase(),
    };
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              avatar: Icon(
                filters.favoritesOnly ? Icons.favorite : Icons.favorite_border,
                size: 18,
                color: AppColors.danger,
              ),
              label: Text('Favoris ($count)'),
              tooltip: count == 0
                  ? 'Touchez le cœur d’une offre pour l’ajouter'
                  : null,
              selected: filters.favoritesOnly,
              showCheckmark: false,
              onSelected: (value) =>
                  onApply(filters.copyWith(favoritesOnly: value)),
            ),
          ),
          for (final search in favorites.searches)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InputChip(
                avatar: const Icon(Icons.bookmark_outline, size: 18),
                label: Text(search.name),
                tooltip: 'Relancer cette recherche',
                deleteButtonTooltipMessage: 'Supprimer',
                onPressed: () => onApply(filters.withSearch(search)),
                onDeleted: () => _remove(context, ref, search),
              ),
            ),
          if (filters.isSearch)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Enregistrer la recherche'),
                onPressed: () => _save(context, ref),
              ),
            ),
          // Suggestions : recherches prêtes à l'emploi, même sans compte.
          for (final search in suggestedSearches)
            if (!saved.contains(search.name.toLowerCase()))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.lightbulb_outline, size: 18),
                  label: Text(search.name),
                  tooltip: 'Recherche suggérée',
                  onPressed: () => onApply(filters.withSearch(search)),
                ),
              ),
        ],
      ),
    );
  }
}
