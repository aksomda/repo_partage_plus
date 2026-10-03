import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test(
    'instantané : une clé à null efface la copie au lieu de planter',
    () async {
      final store = await memoryStore();
      await store.saveSnapshot({
        'admin': {'pending_offers': []},
        'offers': [],
      });

      // Réponse GET /sync d'un non-admin : `admin` vaut null.
      await store.saveSnapshot({
        'admin': null,
        'offers': [1],
      });

      expect(await store.readSnapshot('admin'), isNull);
      expect(await store.readSnapshot('offers'), [1]);
      expect(await store.lastSync(), isNotNull);
    },
  );

  test('réglage à null : effacé', () async {
    final store = await memoryStore();
    await store.saveSetting('radius', 5);
    await store.saveSetting('radius', null);

    expect(await store.readSetting<int>('radius'), isNull);
  });
}
