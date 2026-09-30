import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';

/// Taille maximale du cache de tuiles sur l'appareil.
const mapCacheMaxBytes = 300 * 1024 * 1024;

/// Place le cache de tuiles dans un dossier persistant (le dossier de cache
/// par défaut peut être vidé à tout moment par le système). À appeler au
/// démarrage, avant le premier affichage d'une carte. Sans effet sur le web,
/// où c'est le cache du navigateur qui s'applique.
Future<void> initMapCache() async {
  if (kIsWeb) return;
  try {
    final directory = await getApplicationSupportDirectory();
    BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: '${directory.path}/map_tiles',
      maxCacheSize: mapCacheMaxBytes,
    );
  } catch (error) {
    // Cache indisponible : la carte fonctionne quand même en ligne.
    debugPrint('Cache de carte indisponible : $error');
  }
}

/// Cache de tuiles « hors ligne d'abord ».
///
/// Le cache intégré de flutter_map ne ressert pas une tuile périmée quand le
/// réseau échoue : il affiche alors une tuile vide. Hors ligne, ce décorateur
/// présente donc les tuiles en cache comme fraîches, pour qu'elles soient
/// affichées sans tenter le réseau. En ligne, rien ne change : les tuiles
/// périmées sont rafraîchies normalement.
class OfflineFirstCachingProvider implements MapCachingProvider {
  OfflineFirstCachingProvider(this._inner, this._isOnline);

  final MapCachingProvider _inner;
  final bool Function() _isOnline;

  @override
  bool get isSupported => _inner.isSupported;

  @override
  Future<CachedMapTile?> getTile(String url) async {
    final tile = await _inner.getTile(url);
    if (tile == null || _isOnline() || !tile.metadata.isStale) return tile;
    return (
      bytes: tile.bytes,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.timestamp().add(const Duration(hours: 1)),
        lastModified: tile.metadata.lastModified,
        etag: tile.metadata.etag,
      ),
    );
  }

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) => _inner.putTile(url: url, metadata: metadata, bytes: bytes);
}

/// Fournisseur de tuiles de la carte. Une instance par carte affichée :
/// TileLayer le libère quand la carte disparaît.
TileProvider offlineFirstTileProvider({
  required bool Function() isOnline,
  MapCachingProvider? cache,
}) {
  return NetworkTileProvider(
    cachingProvider: OfflineFirstCachingProvider(
      cache ?? BuiltInMapCachingProvider.getOrCreateInstance(),
      isOnline,
    ),
    // Tuile jamais consultée et pas de réseau : case vide plutôt qu'erreur.
    silenceExceptions: true,
  );
}
