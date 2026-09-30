import 'dart:math' as math;

/// Calculs géographiques faits sur l'appareil (fonctionnent hors ligne).

const _earthRadiusKm = 6371.0088;

double _rad(double degrees) => degrees * math.pi / 180;

/// Distance à vol d'oiseau en km entre deux points (formule de haversine).
double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusKm * math.asin(math.min(1, math.sqrt(a)));
}

/// Les rues ne vont pas en ligne droite : distance à parcourir estimée
/// (facteur de détour moyen en ville, sans service d'itinéraire).
const detourFactor = 1.3;

/// Vitesse de marche moyenne, en km/h.
const walkingSpeedKmh = 4.5;

/// Distance à parcourir estimée (km) à partir de la distance à vol d'oiseau.
double estimatedTravelKm(double straightKm) => straightKm * detourFactor;

/// Temps de marche estimé, en minutes (au moins 1).
int walkingMinutes(double straightKm) =>
    math.max(1, (estimatedTravelKm(straightKm) / walkingSpeedKmh * 60).round());

/// « 12 min à pied », « 1 h 05 à pied ».
String formatWalkingTime(double straightKm) {
  final minutes = walkingMinutes(straightKm);
  if (minutes < 60) return '$minutes min à pied';
  final hours = minutes ~/ 60;
  final rest = (minutes % 60).toString().padLeft(2, '0');
  return '$hours h $rest à pied';
}

// ---------- Regroupement géographique ----------

/// Groupe d'éléments proches les uns des autres (même quartier, même rue…).
class GeoCluster<T> {
  GeoCluster(this.lat, this.lng, this.items);

  /// Centre du groupe (moyenne des positions).
  double lat;
  double lng;
  final List<T> items;

  int get size => items.length;

  /// Distance entre le centre du groupe et un point, en km.
  double distanceFrom(double fromLat, double fromLng) =>
      haversineKm(fromLat, fromLng, lat, lng);
}

/// Regroupe les éléments situés à moins de [radiusKm] du centre d'un groupe.
///
/// Algorithme glouton en une passe, déterministe : les éléments sont d'abord
/// triés du plus proche au plus éloigné de ([originLat], [originLng]) si
/// fournis, puis chacun rejoint le groupe le plus proche dont le centre est à
/// moins de [radiusKm], ou en crée un nouveau. Le centre est recalculé à
/// chaque ajout. Les groupes sont renvoyés du plus proche au plus éloigné.
List<GeoCluster<T>> clusterByProximity<T>(
  List<T> items, {
  required double Function(T) lat,
  required double Function(T) lng,
  required double radiusKm,
  double? originLat,
  double? originLng,
}) {
  final hasOrigin = originLat != null && originLng != null;
  final sorted = [...items];
  if (hasOrigin) {
    sorted.sort(
      (a, b) => haversineKm(
        originLat,
        originLng,
        lat(a),
        lng(a),
      ).compareTo(haversineKm(originLat, originLng, lat(b), lng(b))),
    );
  }

  final clusters = <GeoCluster<T>>[];
  for (final item in sorted) {
    final itemLat = lat(item);
    final itemLng = lng(item);

    GeoCluster<T>? best;
    var bestKm = double.infinity;
    for (final cluster in clusters) {
      final km = haversineKm(cluster.lat, cluster.lng, itemLat, itemLng);
      if (km <= radiusKm && km < bestKm) {
        best = cluster;
        bestKm = km;
      }
    }

    if (best == null) {
      clusters.add(GeoCluster(itemLat, itemLng, [item]));
    } else {
      final n = best.items.length;
      best.items.add(item);
      best.lat = (best.lat * n + itemLat) / (n + 1);
      best.lng = (best.lng * n + itemLng) / (n + 1);
    }
  }

  if (hasOrigin) {
    clusters.sort(
      (a, b) => a
          .distanceFrom(originLat, originLng)
          .compareTo(b.distanceFrom(originLat, originLng)),
    );
  }
  return clusters;
}

/// Rayon de regroupement adapté au zoom de la carte : les repères à moins
/// d'environ [pixels] l'un de l'autre à l'écran sont fusionnés.
double clusterRadiusKmForZoom(
  double zoom,
  double latitude, {
  double pixels = 60,
}) {
  // Taille d'un pixel au sol (projection Web Mercator, tuiles de 256 px).
  final metersPerPixel =
      156543.03392 * math.cos(_rad(latitude)) / math.pow(2, zoom);
  return metersPerPixel * pixels / 1000;
}
