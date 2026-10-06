import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/offline/outbox.dart';
import 'package:repo_partage_plus/core/router/app_router.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';

import 'helpers.dart';

final _now = DateTime.now().toUtc();
String _ago(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toIso8601String();

Future<LocalStore> _store(WidgetTester tester, Map<String, dynamic> data) {
  return tester
      .runAsync(() async {
        final store = await memoryStore();
        await store.saveSnapshot(data);
        return store;
      })
      .then((store) => store!);
}

Future<void> _pump(
  WidgetTester tester,
  LocalStore store,
  String location, {
  bool loggedIn = true,
}) async {
  final overrides = (await tester.runAsync(() => testOverrides(store: store)))!;
  final router = createRouter(
    initialLocation: location,
    isLoggedIn: () => loggedIn,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        if (loggedIn) initialTokenProvider.overrideWithValue('jeton'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('seules les images JPEG, PNG et WebP sont acceptées', () {
    Uint8List bytes(List<int> head) =>
        Uint8List.fromList([...head, ...List.filled(16, 0)]);
    expect(imageMimeType(bytes([0xff, 0xd8, 0xff])), 'image/jpeg');
    expect(imageMimeType(bytes([0x89, 0x50, 0x4e, 0x47])), 'image/png');
    expect(
      imageMimeType(
        Uint8List.fromList([
          ...'RIFF'.codeUnits,
          0,
          0,
          0,
          0,
          ...'WEBP'.codeUnits,
        ]),
      ),
      'image/webp',
    );
    expect(imageMimeType(bytes('%PDF-1.4'.codeUnits)), isNull);
    expect(imageMimeType(bytes('GIF89a'.codeUnits)), isNull);
  });

  testWidgets(
    'utilisateur : notifications et messages en mini chat, envoi hors ligne',
    (tester) async {
      final store = await _store(tester, {
        'profile': {'id': 3, 'name': 'Awa Traoré', 'role': 'beneficiary'},
        'notifications': [
          {
            'id': 1,
            'type': 'reservation_confirmed',
            'title': 'Réservation confirmée',
            'body': 'Votre panier vous attend',
            'created_at': _ago(30),
          },
          // Doublon d'un message : pas de seconde bulle.
          {
            'id': 2,
            'type': 'message',
            'title': 'Message de l’administration',
            'body': 'Bonjour Awa',
            'created_at': _ago(10),
          },
        ],
        'messages': [
          {
            'id': 9,
            'user_id': 3,
            'from_admin': 1,
            'body': 'Bonjour Awa',
            'photos_count': 0,
            'user_name': 'Awa Traoré',
            'created_at': _ago(10),
          },
        ],
      });
      await _pump(tester, store, AppRoutes.notifications);

      expect(find.text('Réservation confirmée'), findsOneWidget);
      expect(find.text('Votre panier vous attend'), findsOneWidget);
      expect(find.text('Bonjour Awa'), findsOneWidget);
      expect(find.text('Administration'), findsOneWidget);
      expect(find.byTooltip('Joindre une image'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Merci !');
      await tester.pump();
      await tester.tap(find.byTooltip('Envoyer'));
      await tester.pumpAndSettle();

      expect(find.text('Merci !'), findsOneWidget);
      expect(find.text('En attente d’envoi'), findsOneWidget);

      final actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
      final kinds = actions.map((a) => a.kind).toList();
      // Ouverture : message de l'admin et notifications marqués lus.
      expect(kinds, containsAll(['message.read', 'notification.read_all']));
      final sent = actions.singleWhere((a) => a.kind == 'message.send');
      expect(sent.path, '/messages');
      expect(sent.body, {'body': 'Merci !', 'photos': <String>[]});
    },
  );

  testWidgets('admin : conversations puis réponse à un utilisateur', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = await _store(tester, {
      'profile': {'id': 1, 'name': 'Admin', 'role': 'admin'},
      'messages': [
        {
          'id': 4,
          'user_id': 3,
          'from_admin': 0,
          'body': 'Le panier était abîmé',
          'photos_count': 0,
          'user_name': 'Awa Traoré',
          'created_at': _ago(20),
        },
        {
          'id': 5,
          'user_id': 7,
          'from_admin': 1,
          'body': 'Votre offre est en ligne',
          'photos_count': 0,
          'read_at': _ago(1),
          'user_name': 'Jean Dupont',
          'created_at': _ago(60),
        },
      ],
    });
    await _pump(tester, store, AppRoutes.notifications);

    expect(find.text('Awa Traoré'), findsOneWidget);
    expect(find.text('Vous : Votre offre est en ligne'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // non lu

    await tester.tap(find.text('Awa Traoré'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Awa Traoré'), findsOneWidget);
    expect(find.text('Le panier était abîmé'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Nous regardons ça');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();

    final actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
    final sent = actions.singleWhere((a) => a.kind == 'message.send');
    expect(sent.body, {
      'body': 'Nous regardons ça',
      'photos': <String>[],
      'user_id': 3,
    });
    final read = actions.singleWhere((a) => a.kind == 'message.read');
    expect(read.body, {'user_id': 3});
  });

  testWidgets('sans compte : le mini chat redirige vers la connexion', (
    tester,
  ) async {
    final store = await _store(tester, {});
    await _pump(tester, store, AppRoutes.notifications, loggedIn: false);

    expect(find.byTooltip('Envoyer'), findsNothing);
    expect(find.text('Se connecter'), findsWidgets);
  });
}
