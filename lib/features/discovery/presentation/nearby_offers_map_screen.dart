import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import 'package:repo_partage_plus/core/location/geo.dart';
import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/discovery/presentation/location_picker_screen.dart';
import 'package:repo_partage_plus/features/discovery/presentation/widgets/discovery_widgets.dart';
import 'package:repo_partage_plus/features/favorites/data/favorites.dart';
import 'package:repo_partage_plus/features/offers/data/offers_repository.dart';
import 'package:repo_partage_plus/features/offers/presentation/widgets/offer_widgets.dart';

/// Carte des offres autour du point de départ (sans compte).
class NearbyOffersMapScreen extends ConsumerStatefulWidget {
  const NearbyOffersMapScreen({super.key});

  @override
  ConsumerState<NearbyOffersMapScreen> createState() =>
      _NearbyOffersMapScreenState();
}

class _NearbyOffersMapScreenState extends ConsumerState<NearbyOffersMapScreen> {
  final _map = MapController();
  Json? _selected;

  /// Zoom courant, arrondi au demi-niveau (recalcule les regroupements).
  double _zoom = 13;

  void _onMove(MapCamera camera) {
    final zoom = (camera.zoom * 2).round() / 2;
    if (zoom != _zoom) setState(() => _zoom = zoom);
  }

  Marker _offerMarker(Json offer) {
    return Marker(
      point: LatLng(
        (offer['latitude'] as num).toDouble(),
        (offer['longitude'] as num).toDouble(),
      ),
      width: 44,
      height: 44,
      alignment: Alignment.topCenter,
      child: GestureDetector(
        onTap: () => setState(() => _selected = offer),
        child: Icon(
          Icons.location_on,
          size: 44,
          color: _selected?['id'] == offer['id']
              ? AppColors.accent
              : AppColors.primary,
        ),
      ),
    );
  }

  /// Groupe d'offres proches : bulle avec leur nombre ; toucher zoome dessus.
  Marker _clusterMarker(GeoCluster<Json> cluster) {
    final size = 34.0 + (cluster.size.clamp(2, 20) - 2) * 1.5;
    return Marker(
      point: LatLng(cluster.lat, cluster.lng),
      width: size,
      height: size,
      child: GestureDetector(
        onTap: () => _map.move(
          LatLng(cluster.lat, cluster.lng),
          (_map.camera.zoom + 2).clamp(3, 18).toDouble(),
        ),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
          ),
          child: Text(
            '${cluster.size}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final place = ref.watch(originProvider).place;
    // Mêmes filtres que la liste (catégorie, prix, urgence, texte, rayon,
    // favoris) : ce qui est affiché ici est ce qui est listé à l'accueil.
    final filters = ref.watch(offerFiltersProvider);
    final filtersNotifier = ref.read(offerFiltersProvider.notifier);
    final offers = filterOffersByOwner(
      available: ref.watch(availableOffersProvider),
      mine: const [],
      origin: place,
      filters: filters.copyWith(owner: OfferOwner.all),
      favoriteIds: ref.watch(favoritesProvider).offerIds,
    );
    final filtered =
        filters.isSearch || filters.hasRefinements || filters.favoritesOnly;
    final center = place ?? defaultCenter;

    // Repères proches regroupés : le rayon suit le zoom (~60 px à l'écran).
    final clusters = clusterByProximity(
      offers,
      lat: (offer) => (offer['latitude'] as num).toDouble(),
      lng: (offer) => (offer['longitude'] as num).toDouble(),
      radiusKm: clusterRadiusKmForZoom(_zoom, center.lat),
    );

    // Le point de départ change : la carte le suit.
    ref.listen(originProvider, (previous, next) {
      final moved = next.place;
      if (moved != null && moved != previous?.place) {
        _map.move(LatLng(moved.lat, moved.lng), _map.camera.zoom);
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Offres à proximité')),
      body: Column(
        children: [
          const OriginBar(),
          CategoryFilterChips(filters: filters, onApply: filtersNotifier.apply),
          RefineFilterBar(
            filters: filters,
            onApply: filtersNotifier.apply,
            onReset: filtersNotifier.reset,
            hasOrigin: place != null,
            onMap: true,
          ),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: LatLng(center.lat, center.lng),
                    initialZoom: _zoom,
                    onTap: (_, _) => setState(() => _selected = null),
                    onPositionChanged: (camera, _) => _onMove(camera),
                  ),
                  children: [
                    const OsmTileLayer(),
                    MarkerLayer(
                      markers: [
                        if (place != null)
                          Marker(
                            point: LatLng(place.lat, place.lng),
                            width: 22,
                            height: 22,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                        for (final cluster in clusters)
                          if (cluster.size == 1)
                            _offerMarker(cluster.items.single)
                          else
                            _clusterMarker(cluster),
                      ],
                    ),
                  ],
                ),
                const Positioned(right: 8, bottom: 8, child: OsmAttribution()),
                const Positioned(
                  left: 12,
                  right: 12,
                  bottom: 36,
                  child: Center(child: OfflineMapNotice()),
                ),
                if (offers.isEmpty)
                  Positioned(
                    left: 16,
                    right: 16,
                    top: 16,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              place == null
                                  ? 'Position inconnue : choisissez un point '
                                        'de départ.'
                                  : filtered
                                  ? 'Aucune offre ne correspond aux '
                                        'filtres${_within(filters.radiusKm)}.'
                                  : 'Aucune offre${_within(filters.radiusKm)}.',
                              textAlign: TextAlign.center,
                            ),
                            if (filtered)
                              TextButton.icon(
                                onPressed: filtersNotifier.reset,
                                icon: const Icon(Icons.filter_alt_off_outlined),
                                label: const Text('Effacer les filtres'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_selected != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 24,
                    child: OfferCard(
                      offer: _selected!,
                      onTap: () =>
                          context.push(AppRoutes.offer('${_selected!['id']}')),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const AppBottomNav(current: 1),
    );
  }
}

/// « dans un rayon de 10 km », rien si le rayon est illimité.
String _within(double km) =>
    km.isFinite ? ' dans un rayon de ${radiusLabel(km)}' : '';
