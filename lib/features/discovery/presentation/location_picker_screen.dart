import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import 'package:repo_partage_plus/core/location/location.dart';
import 'package:repo_partage_plus/core/maps/offline_tiles.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';

/// Fond de carte OpenStreetMap commun aux écrans de carte. Les tuiles
/// consultées sont gardées sur l'appareil et réaffichées hors ligne.
class OsmTileLayer extends ConsumerStatefulWidget {
  const OsmTileLayer({super.key});

  @override
  ConsumerState<OsmTileLayer> createState() => _OsmTileLayerState();
}

class _OsmTileLayerState extends ConsumerState<OsmTileLayer> {
  // Libéré par TileLayer quand la carte disparaît.
  late final _tiles = offlineFirstTileProvider(
    isOnline: () => ref.read(syncControllerProvider).online,
  );

  @override
  Widget build(BuildContext context) {
    return TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.example.repo_partage_plus',
      tileProvider: _tiles,
    );
  }
}

/// Bandeau affiché sur une carte hors ligne.
class OfflineMapNotice extends ConsumerWidget {
  const OfflineMapNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(syncControllerProvider).online) return const SizedBox();
    return const Card(
      color: AppColors.text,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 16, color: Colors.white),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'Hors ligne : seules les zones déjà consultées s’affichent',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Choix d'un point : toucher / déplacer la carte, rechercher une adresse,
/// ou revenir à la position actuelle. Renvoie le [Place] choisi (pop).
class LocationPickerScreen extends ConsumerStatefulWidget {
  const LocationPickerScreen({super.key, this.title = 'Point de départ'});

  final String title;

  @override
  ConsumerState<LocationPickerScreen> createState() =>
      _LocationPickerScreenState();
}

class _LocationPickerScreenState extends ConsumerState<LocationPickerScreen> {
  final _map = MapController();
  final _search = TextEditingController();
  List<Place> _results = const [];
  var _searching = false;
  var _validating = false;
  var _locating = false;

  late LatLng _center;

  @override
  void initState() {
    super.initState();
    final place = ref.read(originProvider).place ?? defaultCenter;
    _center = LatLng(place.lat, place.lng);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final text = _search.text.trim();
    if (text.length < 3) return;
    setState(() => _searching = true);
    try {
      final results = await ref.read(geocoderProvider).search(text);
      if (!mounted) return;
      setState(() => _results = results);
      if (results.isEmpty) showMessage(context, 'Aucune adresse trouvée');
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Recherche d’adresse indisponible', error: true);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _goTo(Place place) {
    FocusScope.of(context).unfocus();
    setState(() {
      _results = const [];
      _center = LatLng(place.lat, place.lng);
    });
    _map.move(_center, 15);
  }

  Future<void> _useCurrentPosition() async {
    setState(() => _locating = true);
    try {
      final place = await ref.read(locationGatewayProvider).currentPosition();
      if (!mounted) return;
      context.pop(place);
    } catch (error) {
      if (mounted) showMessage(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _validate() async {
    setState(() => _validating = true);
    final label = await ref
        .read(geocoderProvider)
        .nameOf(_center.latitude, _center.longitude);
    if (!mounted) return;
    setState(() => _validating = false);
    context.pop(
      Place(
        lat: _center.latitude,
        lng: _center.longitude,
        label: label ?? 'Point choisi sur la carte',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 14,
              onPositionChanged: (camera, _) => _center = camera.center,
              onTap: (_, point) => _map.move(point, _map.camera.zoom),
            ),
            children: const [OsmTileLayer()],
          ),
          // Repère fixe au centre : c'est le point qui sera choisi.
          const IgnorePointer(
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 40),
                child: Icon(
                  Icons.location_on,
                  size: 48,
                  color: AppColors.danger,
                ),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Column(
              children: [
                Material(
                  elevation: 3,
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _runSearch(),
                    decoration: InputDecoration(
                      hintText: 'Rechercher une adresse, un quartier…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.arrow_forward),
                              tooltip: 'Rechercher',
                              onPressed: _runSearch,
                            ),
                    ),
                  ),
                ),
                if (_results.isNotEmpty)
                  Card(
                    margin: const EdgeInsets.only(top: 4),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final place in _results)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.place_outlined),
                              title: Text(
                                place.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _goTo(place),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.surface,
                    ),
                    onPressed: _locating ? null : _useCurrentPosition,
                    icon: _locating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location),
                    label: const Text('Utiliser ma position actuelle'),
                  ),
                  const SizedBox(height: 8),
                  LoadingButton(
                    label: 'Choisir ce point',
                    loading: _validating,
                    onPressed: _validate,
                  ),
                ],
              ),
            ),
          ),
          const Positioned(right: 8, bottom: 140, child: OsmAttribution()),
          const Positioned(
            left: 12,
            right: 12,
            bottom: 170,
            child: Center(child: OfflineMapNotice()),
          ),
        ],
      ),
    );
  }
}

/// Mention obligatoire des données OpenStreetMap.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      color: Colors.white70,
      child: const Text('© OpenStreetMap', style: TextStyle(fontSize: 10)),
    );
  }
}
