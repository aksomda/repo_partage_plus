import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/maps/offline_tiles.dart';

/// Cache en mémoire contenant une tuile périmée.
class MemoryCache implements MapCachingProvider {
  final tiles = <String, CachedMapTile>{};

  @override
  bool get isSupported => true;

  @override
  Future<CachedMapTile?> getTile(String url) async => tiles[url];

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    tiles[url] = (bytes: bytes ?? tiles[url]!.bytes, metadata: metadata);
  }
}

void main() {
  const url = 'https://tile.openstreetmap.org/15/1/2.png';
  final bytes = Uint8List.fromList([1, 2, 3]);
  late MemoryCache cache;
  var online = true;

  setUp(() {
    cache = MemoryCache();
    cache.tiles[url] = (
      bytes: bytes,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.timestamp().subtract(const Duration(days: 30)),
        lastModified: null,
        etag: 'v1',
      ),
    );
  });

  OfflineFirstCachingProvider provider() =>
      OfflineFirstCachingProvider(cache, () => online);

  test('hors ligne : une tuile périmée est servie comme fraîche', () async {
    online = false;
    final tile = await provider().getTile(url);

    expect(tile!.bytes, bytes);
    expect(tile.metadata.isStale, isFalse);
    expect(tile.metadata.etag, 'v1');
  });

  test('en ligne : la tuile périmée reste à rafraîchir', () async {
    online = true;
    final tile = await provider().getTile(url);
    expect(tile!.metadata.isStale, isTrue);
  });

  test('tuile jamais consultée : rien (case vide hors ligne)', () async {
    online = false;
    expect(await provider().getTile('https://autre/tuile.png'), isNull);
  });

  test('les nouvelles tuiles sont enregistrées dans le cache', () async {
    final fresh = CachedMapTileMetadata(
      staleAt: DateTime.timestamp().add(const Duration(days: 7)),
      lastModified: null,
      etag: 'v2',
    );
    await provider().putTile(url: url, metadata: fresh, bytes: bytes);
    expect(cache.tiles[url]!.metadata.etag, 'v2');
  });
}
