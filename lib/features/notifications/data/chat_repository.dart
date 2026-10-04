import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';

/// Nombre maximal d'images par message (comme le serveur).
const maxChatPhotos = 3;

/// Taille maximale d'une image (comme le serveur).
const maxChatPhotoBytes = 3 * 1024 * 1024;

/// Image jointe à un message pas encore envoyé.
typedef ChatPhoto = ({Uint8List bytes, String mime});

/// Type d'image d'après ses premiers octets (JPEG, PNG ou WebP), comme le
/// serveur ; null : pas une image acceptée.
String? imageMimeType(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e) {
    return 'image/png';
  }
  if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

/// Élément du fil : notification de la plateforme, message envoyé ou reçu,
/// ou message pas encore envoyé (file d'attente).
class ChatItem {
  const ChatItem({
    required this.at,
    required this.mine,
    this.system = false,
    this.title,
    this.body,
    this.senderName,
    this.messageId,
    this.photosCount = 0,
    this.localPhotos = const [],
    this.pending = false,
    this.error,
    this.read = false,
  });

  final DateTime at;

  /// Écrit par la personne connectée (bulle à droite).
  final bool mine;

  /// Notification automatique de la plateforme (réservation, retrait…).
  final bool system;
  final String? title;
  final String? body;
  final String? senderName;

  /// Message enregistré sur le serveur (images à télécharger).
  final int? messageId;
  final int photosCount;

  /// Images d'un message pas encore envoyé.
  final List<Uint8List> localPhotos;
  final bool pending;

  /// Refusé par le serveur : ne sera pas renvoyé.
  final String? error;

  /// Lu par le destinataire (messages envoyés).
  final bool read;
}

DateTime _date(Object? value) =>
    DateTime.tryParse('${value ?? ''}')?.toLocal() ??
    DateTime.fromMillisecondsSinceEpoch(0);

bool _flag(Object? value) => value == true || value == 1;

/// Messages du mini chat copiés sur l'appareil (sa conversation, ou toutes
/// pour un administrateur).
final chatMessagesProvider = Provider<List<Json>>(
  (ref) => ref.watch(snapshotListProvider('messages')),
);

/// Messages écrits sur cet appareil et pas encore acceptés par le serveur.
final _outgoingProvider = Provider<List<PendingAction>>((ref) {
  final actions = ref.watch(pendingActionsProvider).value ?? const [];
  return actions.where((action) => action.kind == 'message.send').toList();
});

List<Uint8List> _decodePhotos(Object? photos) => [
  if (photos is List)
    for (final photo in photos.whereType<String>())
      base64Decode(photo.substring(photo.indexOf(',') + 1)),
];

ChatItem _outgoing(PendingAction action) => ChatItem(
  at: action.createdAt.toLocal(),
  mine: true,
  body: action.body?['body'] as String?,
  localPhotos: _decodePhotos(action.body?['photos']),
  pending: !action.isRejected,
  error: action.error,
);

ChatItem _message(Json message, {required bool viewerIsAdmin}) {
  final fromAdmin = _flag(message['from_admin']);
  return ChatItem(
    at: _date(message['created_at']),
    mine: fromAdmin == viewerIsAdmin,
    body: message['body'] as String?,
    senderName: fromAdmin ? 'Administration' : message['user_name'] as String?,
    messageId: message['id'] as int?,
    photosCount: (message['photos_count'] as num?)?.toInt() ?? 0,
    read: message['read_at'] != null,
  );
}

/// Fil de l'utilisateur connecté : notifications de la plateforme et
/// échanges avec l'administration, du plus récent au plus ancien.
final userChatFeedProvider = Provider<List<ChatItem>>((ref) {
  final items = [
    for (final n in ref.watch(snapshotListProvider('notifications')))
      // Les messages ont déjà leur bulle : pas de doublon.
      if (n['type'] != 'message')
        ChatItem(
          at: _date(n['created_at']),
          mine: false,
          system: true,
          title: n['title'] as String?,
          body: n['body'] as String?,
          senderName: 'Partage+',
        ),
    for (final m in ref.watch(chatMessagesProvider))
      _message(m, viewerIsAdmin: false),
    for (final action in ref.watch(_outgoingProvider)) _outgoing(action),
  ];
  return items..sort((a, b) => b.at.compareTo(a.at));
});

/// Conversation d'un utilisateur, vue par l'administrateur.
final adminChatFeedProvider = Provider.family<List<ChatItem>, int>((
  ref,
  userId,
) {
  final items = [
    for (final m in ref.watch(chatMessagesProvider))
      if (m['user_id'] == userId) _message(m, viewerIsAdmin: true),
    for (final action in ref.watch(_outgoingProvider))
      if (action.body?['user_id'] == userId) _outgoing(action),
  ];
  return items..sort((a, b) => b.at.compareTo(a.at));
});

/// Résumé d'une conversation (liste de l'administrateur).
typedef Conversation = ({int userId, String name, Json last, int unread});

/// Conversations, la plus récente d'abord, avec le nombre de messages non
/// lus par l'administration.
final conversationsProvider = Provider<List<Conversation>>((ref) {
  final byUser = <int, List<Json>>{};
  for (final m in ref.watch(chatMessagesProvider)) {
    final userId = m['user_id'];
    if (userId is int) (byUser[userId] ??= []).add(m);
  }
  final conversations = [
    for (final MapEntry(key: userId, value: messages) in byUser.entries)
      (
        userId: userId,
        name: messages.first['user_name'] as String? ?? 'Utilisateur',
        last: messages.reduce(
          (a, b) => (a['id'] as int) > (b['id'] as int) ? a : b,
        ),
        unread: messages
            .where((m) => !_flag(m['from_admin']) && m['read_at'] == null)
            .length,
      ),
  ];
  return conversations
    ..sort((a, b) => (b.last['id'] as int).compareTo(a.last['id'] as int));
});

/// Image d'un message : copie locale si déjà téléchargée, sinon serveur
/// (puis gardée sur l'appareil). null : indisponible (hors ligne…).
final messagePhotoProvider = FutureProvider.family<Uint8List?, (int, int)>((
  ref,
  key,
) async {
  final (messageId, position) = key;
  final store = ref.read(localStoreProvider);
  final cacheKey = 'message:$messageId:$position';
  final cached = await store.readImage(cacheKey);
  if (cached != null) return cached;
  try {
    final response = await ref
        .read(dioProvider)
        .get<List<int>>(
          ApiEndpoints.messagePhoto(messageId, position),
          options: Options(responseType: ResponseType.bytes),
        );
    final bytes = Uint8List.fromList(response.data ?? const []);
    if (bytes.isEmpty) return null;
    await store.saveImage(cacheKey, bytes);
    return bytes;
  } on DioException {
    return null;
  }
});

/// Envoi des messages et accusés de lecture : tout passe par la file
/// d'attente (envoyé tout de suite, ou au retour de la connexion).
class ChatRepository {
  ChatRepository(this._sync, this._ref);

  final SyncController _sync;
  final Ref _ref;

  /// [userId] : destinataire, pour un administrateur ; null sinon.
  Future<SubmitResult> send({
    String? text,
    List<ChatPhoto> photos = const [],
    int? userId,
  }) {
    final body = text?.trim() ?? '';
    return _sync.submit(
      PendingAction(
        kind: 'message.send',
        method: 'POST',
        path: ApiEndpoints.messages,
        body: {
          if (body.isNotEmpty) 'body': body,
          'photos': [
            for (final photo in photos)
              'data:${photo.mime};base64,${base64Encode(photo.bytes)}',
          ],
          'user_id': ?userId,
        },
        targetId: userId,
        label: body.isNotEmpty
            ? 'Message « ${body.length > 30 ? '${body.substring(0, 30)}…' : body} »'
            : 'Message avec image',
      ),
    );
  }

  /// Marque la conversation comme lue (et, pour un utilisateur, ses
  /// notifications), sans doublon dans la file si déjà demandé.
  Future<void> markRead({int? userId}) async {
    final waiting = _ref.read(waitingActionsProvider);
    bool queued(String kind) => waiting.any(
      (action) => action.kind == kind && action.targetId == userId,
    );

    final unreadMessages = _ref
        .read(chatMessagesProvider)
        .where(
          (m) =>
              m['read_at'] == null &&
              _flag(m['from_admin']) == (userId == null) &&
              (userId == null || m['user_id'] == userId),
        );
    if (unreadMessages.isNotEmpty && !queued('message.read')) {
      await _sync.submit(
        PendingAction(
          kind: 'message.read',
          method: 'PATCH',
          path: ApiEndpoints.readMessages,
          body: {'user_id': ?userId},
          targetId: userId,
          label: 'Messages lus',
        ),
      );
    }

    if (userId != null) return;
    final unreadNotifications = _ref
        .read(snapshotListProvider('notifications'))
        .where((n) => n['read_at'] == null);
    if (unreadNotifications.isNotEmpty && !queued('notification.read_all')) {
      await _sync.submit(
        PendingAction(
          kind: 'notification.read_all',
          method: 'PATCH',
          path: ApiEndpoints.readAllNotifications,
          label: 'Notifications lues',
        ),
      );
    }
  }
}

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => ChatRepository(ref.read(syncControllerProvider.notifier), ref),
);
