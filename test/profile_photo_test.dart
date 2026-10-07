import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_config.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/core/widgets/profile_avatar.dart';
import 'package:repo_partage_plus/features/auth/data/profile_repository.dart';

import 'helpers.dart';

void main() {
  group('photo de profil', () {
    test('URL construite à partir de photo_path', () {
      expect(profilePhotoUrl({'photo_path': null}), isNull);
      expect(profilePhotoUrl(null), isNull);
      expect(
        profilePhotoUrl({'photo_path': '/users/4/photo?v=1'}),
        '${ApiConfig.baseUrl}/users/4/photo?v=1',
      );
    });

    testWidgets('initiales sans photo, image sinon', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ProfileAvatar(name: 'Levi Ouattara')),
      );
      expect(find.text('LO'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: ProfileAvatar(
            name: 'Levi Ouattara',
            photoUrl: 'http://localhost/users/4/photo?v=1',
          ),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
    });

    test('envoi puis retrait : copie locale du profil mise à jour', () async {
      final store = await memoryStore();
      await store.saveSnapshot({
        'profile': {'id': 4, 'name': 'Levi Ouattara', 'photo_path': null},
      });
      final server = FakeServer(
        (request) async => jsonResponse(200, {
          'id': 4,
          'name': 'Levi Ouattara',
          'photo_path': request.method == 'PUT' ? '/users/4/photo?v=9' : null,
        }),
      );
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          onlineProvider.overrideWith((ref) => Stream.value(true)),
          dioProvider.overrideWithValue(Dio()..httpClientAdapter = server),
        ],
      );
      addTearDown(container.dispose);
      final repository = container.read(profileRepositoryProvider);

      await repository.setPhoto('data:image/jpeg;base64,/9j/4A==');
      expect(server.requests.last.method, 'PUT');
      expect(server.requests.last.path, '/users/me/photo');
      expect(server.requests.last.data, {
        'photo': 'data:image/jpeg;base64,/9j/4A==',
      });
      var profile = await store.readSnapshot('profile') as Map;
      expect(profile['photo_path'], '/users/4/photo?v=9');
      expect(profile['name'], 'Levi Ouattara');

      await repository.setPhoto(null);
      expect(server.requests.last.method, 'DELETE');
      profile = await store.readSnapshot('profile') as Map;
      expect(profile['photo_path'], isNull);
    });

    test('hors ligne : message clair, profil inchangé', () async {
      final store = await memoryStore();
      final container = ProviderContainer(
        overrides: [
          localStoreProvider.overrideWithValue(store),
          onlineProvider.overrideWith((ref) => Stream.value(false)),
          dioProvider.overrideWithValue(
            Dio()..httpClientAdapter = FakeServer(networkDown),
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container
            .read(profileRepositoryProvider)
            .setPhoto('data:image/jpeg;base64,/9j/4A=='),
        throwsA(
          isA<ApiException>().having((e) => e.isNetwork, 'réseau', isTrue),
        ),
      );
    });
  });
}
