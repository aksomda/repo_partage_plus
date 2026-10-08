import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:repo_partage_plus/core/network/api_client.dart';
import 'package:repo_partage_plus/core/network/api_endpoints.dart';
import 'package:repo_partage_plus/core/offline/offline_data.dart';
import 'package:repo_partage_plus/core/offline/pending_action.dart';
import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/router/app_routes.dart';
import 'package:repo_partage_plus/core/storage/local_store.dart';
import 'package:repo_partage_plus/features/auth/data/auth_repository.dart';

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
    this.link,
    this.direct = false,
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

  /// Écran lié à une notification (réservation, offre), ouvert au toucher.
  final String? link;

  /// Message entre utilisateurs (images servies par une autre route).
  final bool direct;
}

/// Notification d'un message (administration ou utilisateur) : le message
/// s'affiche dans « Messages », pas dans la liste des notifications.
bool _isMessage(Json notification) =>
    notification['type'] == 'message' ||
    notification['type'] == 'direct_message';

DateTime _date(Object? value) =>
    DateTime.tryParse('${value ?? ''}')?.toLocal() ??
    DateTime.fromMillisecondsSinceEpoch(0);

bool _flag(Object? value) => value == true || value == 1;

/// Données jointes à une notification (objet JSON, ou texte JSON).
Json _notificationData(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String && value.isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      return const {};
    }
  }
  return const {};
}

/// Notifications adressées au bénéficiaire : sa réservation s'ouvre.
const _beneficiaryTypes = {
  'reservation_confirmed',
  'pickup_reminder',
  'pickup_done',
};

/// Écran à ouvrir depuis une notification ; null : rien à ouvrir.
String? notificationLink(Json notification) {
  final data = _notificationData(notification['data']);
  final type = notification['type'];
  final reservationId = data['reservation_id'];
  final offerId = data['offer_id'];
  if (type == 'direct_message' && data['peer_id'] is int) {
    return AppRoutes.directConversation(data['peer_id'] as int);
  }
  if (reservationId != null && _beneficiaryTypes.contains(type)) {
    return AppRoutes.confirmation('$reservationId');
  }
  if (reservationId != null) return AppRoutes.myReservations;
  if (offerId != null) return AppRoutes.offer('$offerId');
  return null;
}

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
      if (!_isMessage(n))
        ChatItem(
          at: _date(n['created_at']),
          mine: false,
          system: true,
          title: n['title'] as String?,
          body: n['body'] as String?,
          senderName: 'Partage+',
          read: n['read_at'] != null,
          link: notificationLink(n),
        ),
    for (final m in ref.watch(chatMessagesProvider))
      _message(m, viewerIsAdmin: false),
    for (final action in ref.watch(_outgoingProvider)) _outgoing(action),
  ];
  return items..sort((a, b) => b.at.compareTo(a.at));
});

/// Échanges avec l'administration seulement (écran « Messages »), du plus
/// récent au plus ancien.
final userMessagesFeedProvider = Provider<List<ChatItem>>(
  (ref) => [
    for (final item in ref.watch(userChatFeedProvider))
      if (!item.system) item,
  ],
);

/// Notifications de la plateforme (hors messages), la plus récente d'abord.
final userNotificationsProvider = Provider<List<Json>>((ref) {
  final notifications = [
    for (final n in ref.watch(snapshotListProvider('notifications')))
      if (!_isMessage(n)) n,
  ];
  return notifications
    ..sort((a, b) => _date(b['created_at']).compareTo(_date(a['created_at'])));
});

/// Messages de l'administration pas encore lus.
final unreadTeamMessagesCountProvider = Provider<int>(
  (ref) => ref
      .watch(chatMessagesProvider)
      .where((m) => _flag(m['from_admin']) && m['read_at'] == null)
      .length,
);

/// Messages reçus pas encore lus, administration et utilisateurs
/// (pastille « Messages »).
final unreadMessagesCountProvider = Provider<int>(
  (ref) =>
      ref.watch(unreadTeamMessagesCountProvider) +
      ref.watch(unreadDirectCountProvider),
);

/// Onglet de l'écran des notifications (maquette).
enum NotificationKind {
  reservations('Réservations'),
  infos('Infos'),
  tips('Conseils');

  const NotificationKind(this.label);

  final String label;

  /// Réservations et retraits ; conseils : date limite proche, nouvelles
  /// offres d'une recherche ; le reste (compte, modération) : infos.
  static NotificationKind of(Json notification) {
    final type = '${notification['type']}';
    if (type.startsWith('reservation_') ||
        type.startsWith('pickup_') ||
        type == 'confirm_reminder' ||
        type == 'slot_changed') {
      return reservations;
    }
    if (type == 'expiry_soon' || type == 'search_match') return tips;
    return infos;
  }
}

/// Notifications et messages de l'administration pas encore lus, pour le
/// badge de l'icône Notifications.
final unreadFeedCountProvider = Provider<int>((ref) {
  final notifications = ref
      .watch(snapshotListProvider('notifications'))
      .where((n) => !_isMessage(n) && n['read_at'] == null)
      .length;
  return notifications + ref.watch(unreadMessagesCountProvider);
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

// ---------- Messagerie entre utilisateurs ----------

/// Échanges avec les publieurs ou bénéficiaires, copiés sur l'appareil
/// (envoyés et reçus).
final directMessagesProvider = Provider<List<Json>>(
  (ref) => ref.watch(snapshotListProvider('direct_messages')),
);

/// Messages à un utilisateur écrits sur cet appareil, pas encore acceptés.
final _outgoingDirectProvider = Provider<List<PendingAction>>((ref) {
  final actions = ref.watch(pendingActionsProvider).value ?? const [];
  return actions
      .where((action) => action.kind == 'direct_message.send')
      .toList();
});

/// Résumé d'un échange avec un autre utilisateur (liste « Messages »).
typedef DirectConversation = ({
  int peerId,
  String name,
  String? actor,
  String? offerTitle,
  int? offerId,
  Json last,
  int unread,
});

/// Correspondant d'un message vu par [me] : (id, nom, acteur).
(int, String, String?) _peer(Json message, int? me) {
  final sent = message['sender_id'] == me;
  return (
    (sent ? message['recipient_id'] : message['sender_id']) as int,
    (sent ? message['recipient_name'] : message['sender_name']) as String? ??
        'Utilisateur',
    (sent ? message['recipient_actor'] : message['sender_actor']) as String?,
  );
}

int? _myId(Ref ref) => (ref.watch(profileProvider)?['id'] as num?)?.toInt();

/// Échanges, le plus récent d'abord, avec le nombre de messages non lus.
final directConversationsProvider = Provider<List<DirectConversation>>((ref) {
  final me = _myId(ref);
  final byPeer = <int, List<Json>>{};
  for (final m in ref.watch(directMessagesProvider)) {
    final (peerId, _, _) = _peer(m, me);
    (byPeer[peerId] ??= []).add(m);
  }
  final conversations = [
    for (final MapEntry(key: peerId, value: messages) in byPeer.entries)
      if (messages.reduce((a, b) => (a['id'] as int) > (b['id'] as int) ? a : b)
          case final last)
        (
          peerId: peerId,
          name: _peer(last, me).$2,
          actor: _peer(last, me).$3,
          // Dernière offre dont on a parlé.
          offerTitle: messages
              .map((m) => m['offer_title'] as String?)
              .nonNulls
              .firstOrNull,
          offerId: messages
              .map((m) => (m['offer_id'] as num?)?.toInt())
              .nonNulls
              .firstOrNull,
          last: last,
          unread: messages
              .where((m) => m['recipient_id'] == me && m['read_at'] == null)
              .length,
        ),
  ];
  return conversations
    ..sort((a, b) => (b.last['id'] as int).compareTo(a.last['id'] as int));
});

/// Fil d'un échange avec [peerId], du plus récent au plus ancien.
final directFeedProvider = Provider.family<List<ChatItem>, int>((ref, peerId) {
  final me = _myId(ref);
  final items = [
    for (final m in ref.watch(directMessagesProvider))
      if (_peer(m, me).$1 == peerId)
        ChatItem(
          at: _date(m['created_at']),
          mine: m['sender_id'] == me,
          body: m['body'] as String?,
          senderName: m['sender_id'] == me ? null : m['sender_name'] as String?,
          messageId: m['id'] as int?,
          photosCount: (m['photos_count'] as num?)?.toInt() ?? 0,
          read: m['read_at'] != null,
          direct: true,
        ),
    for (final action in ref.watch(_outgoingDirectProvider))
      if (action.targetId == peerId) _outgoing(action),
  ];
  return items..sort((a, b) => b.at.compareTo(a.at));
});

/// Messages reçus d'autres utilisateurs pas encore lus.
final unreadDirectCountProvider = Provider<int>((ref) {
  final me = _myId(ref);
  return ref
      .watch(directMessagesProvider)
      .where((m) => m['recipient_id'] == me && m['read_at'] == null)
      .length;
});

/// Image d'un message : copie locale si déjà téléchargée, sinon serveur
/// (puis gardée sur l'appareil). null : indisponible (hors ligne…).
final messagePhotoProvider =
    FutureProvider.family<Uint8List?, (int, int, bool)>((ref, key) async {
      final (messageId, position, direct) = key;
      final store = ref.read(localStoreProvider);
      final cacheKey = direct
          ? 'direct_message:$messageId:$position'
          : 'message:$messageId:$position';
      final cached = await store.readImage(cacheKey);
      if (cached != null) return cached;
      try {
        final response = await ref
            .read(dioProvider)
            .get<List<int>>(
              direct
                  ? ApiEndpoints.directMessagePhoto(messageId, position)
                  : ApiEndpoints.messagePhoto(messageId, position),
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

  /// Message à un autre utilisateur ; [offerId] : offre dont on parle
  /// (fiche détail), qui autorise le premier message au publieur.
  Future<SubmitResult> sendDirect({
    required int peerId,
    int? offerId,
    String? text,
    List<ChatPhoto> photos = const [],
  }) {
    final body = text?.trim() ?? '';
    return _sync.submit(
      PendingAction(
        kind: 'direct_message.send',
        method: 'POST',
        path: ApiEndpoints.directMessages,
        body: {
          'recipient_id': peerId,
          'offer_id': ?offerId,
          if (body.isNotEmpty) 'body': body,
          'photos': [
            for (final photo in photos)
              'data:${photo.mime};base64,${base64Encode(photo.bytes)}',
          ],
        },
        targetId: peerId,
        label: body.isNotEmpty
            ? 'Message « ${body.length > 30 ? '${body.substring(0, 30)}…' : body} »'
            : 'Message avec image',
      ),
    );
  }

  /// Marque comme lus les messages reçus de [peerId], sans doublon.
  Future<void> markDirectRead(int peerId) async {
    final me = (_ref.read(profileProvider)?['id'] as num?)?.toInt();
    final unread = _ref
        .read(directMessagesProvider)
        .any(
          (m) =>
              m['sender_id'] == peerId &&
              m['recipient_id'] == me &&
              m['read_at'] == null,
        );
    final queued = _ref
        .read(waitingActionsProvider)
        .any(
          (action) =>
              action.kind == 'direct_message.read' && action.targetId == peerId,
        );
    if (!unread || queued) return;
    await _sync.submit(
      PendingAction(
        kind: 'direct_message.read',
        method: 'PATCH',
        path: ApiEndpoints.readDirectMessages,
        body: {'peer_id': peerId},
        targetId: peerId,
        label: 'Messages lus',
      ),
    );
  }

  /// Marque la conversation comme lue ([messages]) et, pour un utilisateur,
  /// ses notifications ([notifications]), sans doublon dans la file si déjà
  /// demandé.
  Future<void> markRead({
    int? userId,
    bool messages = true,
    bool notifications = true,
  }) async {
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
    if (messages && unreadMessages.isNotEmpty && !queued('message.read')) {
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

    if (userId != null || !notifications) return;
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
