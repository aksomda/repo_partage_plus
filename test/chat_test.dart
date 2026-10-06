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
    'utilisateur : notifications par onglet, messages à part, envoi hors ligne',
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
      // Rangée dans l'onglet « Réservations » ; le message n'est pas listé.
      expect(find.text('Réservations (1)'), findsOneWidget);
      expect(find.text('Bonjour Awa'), findsNothing);
      expect(find.text('1 nouveau message'), findsOneWidget);
      // Écriture de la file : asynchrone, on la laisse se terminer.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      var actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
      // Notifications marquées lues, pas encore le message.
      expect(actions.map((a) => a.kind), ['notification.read_all']);

      await tester.tap(find.text('Messages').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Messages'), findsOneWidget);
      await tester.tap(find.text('Équipe Partage+'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Équipe Partage+'), findsOneWidget);
      expect(find.text('Bonjour Awa'), findsOneWidget);
      expect(find.text('Administration'), findsOneWidget);
      expect(find.text('Votre panier vous attend'), findsNothing);
      expect(find.byTooltip('Joindre une image'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Merci !');
      await tester.pump();
      await tester.tap(find.byTooltip('Envoyer'));
      await tester.pumpAndSettle();

      expect(find.text('Merci !'), findsOneWidget);
      expect(find.text('En attente d’envoi'), findsOneWidget);

      actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
      final kinds = actions.map((a) => a.kind).toList();
      // Ouvertures : notifications puis message de l'admin marqués lus.
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

  testWidgets(
    'fiche détail : écrire au publieur, échange listé, notification à part',
    (tester) async {
      final store = await _store(tester, {
        'profile': {'id': 3, 'name': 'Awa Traoré', 'role': 'beneficiary'},
        'offers': [
          {
            ...publishedOffer(id: 7, title: 'Pains du soir'),
            'donor_id': 2,
            'donor_name': 'Boulangerie du Centre',
          },
        ],
        'notifications': [
          // Doublon d'un message : pas listé avec les notifications.
          {
            'id': 4,
            'type': 'direct_message',
            'title': 'Message de Restaurant Le Partage',
            'body': 'Il reste 2 portions',
            'data': {'peer_id': 5},
            'created_at': _ago(5),
          },
        ],
        'direct_messages': [
          {
            'id': 11,
            'sender_id': 5,
            'recipient_id': 3,
            'offer_id': 9,
            'offer_title': 'Riz sauce arachide',
            'body': 'Il reste 2 portions',
            'photos_count': 0,
            'sender_name': 'Restaurant Le Partage',
            'sender_actor': 'Restaurateur',
            'recipient_name': 'Awa Traoré',
            'created_at': _ago(5),
          },
        ],
      });
      await _pump(tester, store, AppRoutes.offer('7'));

      await tester.tap(find.byTooltip('Écrire au publieur'));
      await tester.pumpAndSettle();
      expect(find.text('Boulangerie du Centre'), findsOneWidget);
      expect(find.text('À propos de « Pains du soir »'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Reste-t-il du pain ?');
      await tester.pump();
      await tester.tap(find.byTooltip('Envoyer'));
      await tester.pumpAndSettle();
      expect(find.text('Reste-t-il du pain ?'), findsOneWidget);

      final actions = (await tester.runAsync(() => Outbox(store.db).all()))!;
      final sent = actions.singleWhere((a) => a.kind == 'direct_message.send');
      expect(sent.path, '/direct-messages');
      expect(sent.body, {
        'recipient_id': 2,
        'offer_id': 7,
        'body': 'Reste-t-il du pain ?',
        'photos': <String>[],
      });

      // Liste des messages : l'échange reçu, non lu, avec son offre.
      await _pump(tester, store, AppRoutes.messages);
      expect(find.text('Restaurant Le Partage'), findsOneWidget);
      expect(find.text('Restaurateur'), findsOneWidget);
      expect(find.text('À propos de « Riz sauce arachide »'), findsOneWidget);
      expect(find.text('Il reste 2 portions'), findsOneWidget);

      // Notifications : le message n'y est pas en double.
      await _pump(tester, store, AppRoutes.notifications);
      expect(find.text('Message de Restaurant Le Partage'), findsNothing);
      expect(find.text('1 nouveau message'), findsOneWidget);
    },
  );

  testWidgets('sans compte : le mini chat redirige vers la connexion', (
    tester,
  ) async {
    final store = await _store(tester, {});
    await _pump(tester, store, AppRoutes.notifications, loggedIn: false);

    expect(find.byTooltip('Envoyer'), findsNothing);
    expect(find.text('Se connecter'), findsWidgets);
  });
}
