import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'package:repo_partage_plus/core/storage/local_store.dart';

/// Point de départ des recherches d'offres.
class Place {
  const Place({
    required this.lat,
    required this.lng,
    required this.label,
    this.isCurrent = false,
  });

  final double lat;
  final double lng;
  final String label;

  /// true : position actuelle de l'appareil ; false : point choisi.
  final bool isCurrent;

  Map<String, Object?> toMap() => {
    'lat': lat,
    'lng': lng,
    'label': label,
    'is_current': isCurrent,
  };

  static Place? fromMap(Object? value) {
    if (value is! Map) return null;
    return Place(
      lat: (value['lat'] as num).toDouble(),
      lng: (value['lng'] as num).toDouble(),
      label: value['label'] as String? ?? 'Point choisi',
      isCurrent: value['is_current'] == true,
    );
  }
}

/// Position par défaut de la carte quand aucune n'est connue (Ouagadougou).
const defaultCenter = Place(lat: 12.3714, lng: -1.5197, label: 'Ouagadougou');

/// Refus ou indisponibilité de la localisation, avec un message lisible.
class LocationFailure implements Exception {
  const LocationFailure(this.message, {this.canOpenSettings = false});

  final String message;

  /// Autorisation refusée définitivement : seuls les réglages peuvent la rendre.
  final bool canOpenSettings;

  @override
  String toString() => message;
}

/// Accès à la position de l'appareil (téléphone, navigateur, Windows…),
/// après autorisation de l'utilisateur. Remplaçable dans les tests.
abstract class LocationGateway {
  Future<Place> currentPosition();
  Future<void> openSettings();
}

class GeolocatorGateway implements LocationGateway {
  @override
  Future<Place> currentPosition() async {
    // geolocator n'existe pas sur Linux.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      throw const LocationFailure(
        'Position indisponible sur Linux : choisissez un point sur la carte.',
      );
    }
    // Sur le web, c'est le navigateur qui gère service et autorisation.
    if (!kIsWeb && !await Geolocator.isLocationServiceEnabled()) {
      throw const LocationFailure(
        'La localisation est désactivée sur cet appareil. '
        'Activez-la ou choisissez un point sur la carte.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationFailure(
        'L’accès à la position a été refusé. Autorisez-le dans les réglages, '
        'ou choisissez un point sur la carte.',
        canOpenSettings: !kIsWeb,
      );
    }
    if (permission == LocationPermission.denied) {
      throw const LocationFailure(
        'Position non autorisée : choisissez un point de départ sur la carte.',
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return Place(
        lat: position.latitude,
        lng: position.longitude,
        label: 'Ma position',
        isCurrent: true,
      );
    } on TimeoutException {
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      if (last != null) {
        return Place(
          lat: last.latitude,
          lng: last.longitude,
          label: 'Ma position',
          isCurrent: true,
        );
      }
      throw const LocationFailure(
        'Position introuvable pour le moment. Réessayez ou choisissez un point.',
      );
    }
  }

  @override
  Future<void> openSettings() => Geolocator.openAppSettings();
}

final locationGatewayProvider = Provider<LocationGateway>(
  (ref) => GeolocatorGateway(),
);

// ---------- Point de départ choisi ----------

class OriginState {
  const OriginState({this.place, this.locating = false, this.error});

  /// null tant qu'aucune position n'est connue.
  final Place? place;
  final bool locating;
  final LocationFailure? error;
}

/// Point de départ des recherches : position actuelle par défaut, ou point
/// choisi par l'utilisateur. Mémorisé sur l'appareil.
class OriginController extends Notifier<OriginState> {
  static const _settingKey = 'origin';

  @override
  OriginState build() {
    Future.microtask(_restore);
    return const OriginState();
  }

  Future<void> _restore() async {
    final saved = Place.fromMap(
      await ref.read(localStoreProvider).readSetting<Object?>(_settingKey),
    );
    if (saved != null && state.place == null) {
      state = OriginState(place: saved);
    }
  }

  /// Demande l'autorisation si besoin, puis utilise la position actuelle.
  Future<bool> useCurrentPosition() async {
    state = OriginState(place: state.place, locating: true);
    try {
      final place = await ref.read(locationGatewayProvider).currentPosition();
      await _set(place);
      return true;
    } on LocationFailure catch (error) {
      state = OriginState(place: state.place, error: error);
      return false;
    } catch (_) {
      state = OriginState(
        place: state.place,
        error: const LocationFailure(
          'Localisation indisponible : choisissez un point sur la carte.',
        ),
      );
      return false;
    }
  }

  Future<void> choose(Place place) => _set(place);

  Future<void> _set(Place place) async {
    state = OriginState(place: place);
    await ref.read(localStoreProvider).saveSetting(_settingKey, place.toMap());
  }
}

final originProvider = NotifierProvider<OriginController, OriginState>(
  OriginController.new,
);

// ---------- Recherche d'adresse (OpenStreetMap Nominatim) ----------

/// Recherche d'adresses et nom d'un point, via OpenStreetMap Nominatim
/// (gratuit, sans clé ; usage modéré : une requête par recherche validée).
class Geocoder {
  Geocoder([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://nominatim.openstreetmap.org',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: {
                'Accept-Language': 'fr',
                // Le navigateur interdit de modifier User-Agent.
                if (!kIsWeb) 'User-Agent': 'PartagePlus/1.0 (app mobile)',
              },
            ),
          );

  final Dio _dio;

  Future<List<Place>> search(String text) async {
    final response = await _dio.get<List<dynamic>>(
      '/search',
      queryParameters: {'q': text, 'format': 'jsonv2', 'limit': 6},
    );
    return [
      for (final item in response.data ?? const [])
        if (item is Map)
          Place(
            lat: double.parse(item['lat'] as String),
            lng: double.parse(item['lon'] as String),
            label: item['display_name'] as String,
          ),
    ];
  }

  /// Nom court du lieu (quartier, ville), ou null si inconnu.
  Future<String?> nameOf(double lat, double lng) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/reverse',
        queryParameters: {
          'lat': lat,
          'lon': lng,
          'format': 'jsonv2',
          'zoom': 16,
        },
      );
      final address = response.data?['address'];
      if (address is Map) {
        final parts = [
          address['road'],
          address['suburb'] ?? address['neighbourhood'],
          address['city'] ?? address['town'] ?? address['village'],
        ].whereType<String>().toList();
        if (parts.isNotEmpty) return parts.join(', ');
      }
      return response.data?['display_name'] as String?;
    } on DioException {
      return null;
    }
  }

  /// Code ISO du pays (ex. `BF`), ou null si inconnu ou hors ligne.
  Future<String?> countryCodeOf(double lat, double lng) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/reverse',
        queryParameters: {
          'lat': lat,
          'lon': lng,
          'format': 'jsonv2',
          'zoom': 3,
        },
      );
      final address = response.data?['address'];
      final code = address is Map ? address['country_code'] : null;
      return code is String ? code.toUpperCase() : null;
    } on DioException {
      return null;
    }
  }
}

final geocoderProvider = Provider<Geocoder>((ref) => Geocoder());
