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

  test('patchSnapshot : remplace des champs sans toucher aux autres', () async {
    final store = await memoryStore();
    await store.saveSnapshot({
      'admin': {
        'settings': {'a': 1},
        'users': [1],
      },
    });
    final syncedAt = await store.lastSync();

    await store.patchSnapshot('admin', {
      'users': [2, 3],
      'users_source': 'firestore',
    });

    expect(await store.readSnapshot('admin'), {
      'settings': {'a': 1},
      'users': [2, 3],
      'users_source': 'firestore',
    });
    expect(await store.lastSync(), syncedAt);

    // Jamais synchronisé : la clé est créée.
    await store.patchSnapshot('autre', {'x': 1});
    expect(await store.readSnapshot('autre'), {'x': 1});
  });

  test('instantané identique : clés inchangées non réécrites', () async {
    final store = await memoryStore();
    final offers = [
      {'id': 1, 'title': 'Pain'},
    ];
    await store.saveSnapshot({'offers': offers, 'notifications': []});

    final emitted = <Object?>[];
    final subscription = store.watchSnapshot('offers').listen(emitted.add);
    await pumpEventQueue();
    expect(emitted, hasLength(1));

    // Même contenu : aucune nouvelle émission (pas de reconstruction d'écran).
    await store.saveSnapshot({
      'offers': [
        {'id': 1, 'title': 'Pain'},
      ],
      'notifications': [],
    });
    await pumpEventQueue();
    expect(emitted, hasLength(1));

    // Contenu modifié : écrit et émis.
    await store.saveSnapshot({
      'offers': [
        {'id': 1, 'title': 'Pain frais'},
      ],
    });
    await pumpEventQueue();
    expect(emitted, hasLength(2));
    expect(await store.readSnapshot('offers'), [
      {'id': 1, 'title': 'Pain frais'},
    ]);
    await subscription.cancel();
  });

  test('réglage à null : effacé', () async {
    final store = await memoryStore();
    await store.saveSetting('radius', 5);
    await store.saveSetting('radius', null);

    expect(await store.readSetting<int>('radius'), isNull);
  });
}
