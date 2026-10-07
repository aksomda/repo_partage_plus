import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'package:repo_partage_plus/core/offline/sync_controller.dart';
import 'package:repo_partage_plus/core/theme/app_theme.dart';
import 'package:repo_partage_plus/core/widgets/profile_avatar.dart';
import 'package:repo_partage_plus/features/auth/presentation/widgets/auth_widgets.dart';
import 'package:repo_partage_plus/features/notifications/data/chat_repository.dart';

/// Mini chat : fil (notifications et messages) et zone de saisie, avec
/// images en pièce jointe uniquement. [userId] : conversation ouverte par
/// un administrateur ; [peerId] : échange avec un autre utilisateur ; sinon
/// celle de l'utilisateur connecté avec l'administration.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({
    super.key,
    this.userId,
    this.messagesOnly = false,
    this.peerId,
    this.offerId,
  });

  final int? userId;

  /// Autre utilisateur (publieur ou bénéficiaire) de l'échange.
  final int? peerId;

  /// Offre dont on parle, jointe aux messages envoyés (fiche détail).
  final int? offerId;

  /// Échanges avec l'administration seulement, sans les notifications
  /// (écran « Messages » de l'utilisateur).
  final bool messagesOnly;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _text = TextEditingController();
  final _photos = <ChatPhoto>[];
  var _marking = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Ce qui est affiché est lu : accusé envoyé (ou mis en file).
  Future<void> _markRead() async {
    if (_marking || !mounted) return;
    _marking = true;
    try {
      final chat = ref.read(chatRepositoryProvider);
      if (widget.peerId case final peerId?) {
        await chat.markDirectRead(peerId);
      } else {
        await chat.markRead(
          userId: widget.userId,
          notifications: !widget.messagesOnly,
        );
      }
    } finally {
      _marking = false;
    }
  }

  bool get _canSend => _text.text.trim().isNotEmpty || _photos.isNotEmpty;

  Future<void> _attach() async {
    final remaining = maxChatPhotos - _photos.length;
    if (remaining <= 0) {
      showMessage(context, '$maxChatPhotos images maximum par message');
      return;
    }

    var source = ImageSource.gallery;
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (mobile) {
      final chosen = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Prendre une photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choisir dans la galerie'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (chosen == null) return;
      source = chosen;
    }

    final List<XFile> files;
    try {
      final picker = ImagePicker();
      if (source == ImageSource.camera) {
        final file = await picker.pickImage(
          source: source,
          maxWidth: 1280,
          maxHeight: 1280,
          imageQuality: 75,
        );
        files = [?file];
      } else {
        files = await picker.pickMultiImage(
          maxWidth: 1280,
          maxHeight: 1280,
          imageQuality: 75,
          limit: remaining > 1 ? remaining : null,
        );
      }
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Impossible d’ouvrir les photos', error: true);
      }
      return;
    }

    final added = <ChatPhoto>[];
    String? problem;
    for (final file in files.take(remaining)) {
      final bytes = await file.readAsBytes();
      final mime = imageMimeType(bytes);
      if (mime == null) {
        problem = 'Seules les images sont acceptées (JPEG, PNG ou WebP)';
      } else if (bytes.length > maxChatPhotoBytes) {
        problem = 'Image trop lourde (3 Mo maximum)';
      } else {
        added.add((bytes: bytes, mime: mime));
      }
    }
    if (!mounted) return;
    if (files.length > remaining) {
      problem ??= '$maxChatPhotos images maximum par message';
    }
    if (problem != null) showMessage(context, problem, error: true);
    setState(() => _photos.addAll(added));
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _text.text;
    final photos = List.of(_photos);
    // Le message est enregistré sur l'appareil : on vide tout de suite.
    _text.clear();
    setState(_photos.clear);

    final chat = ref.read(chatRepositoryProvider);
    final result = widget.peerId == null
        ? await chat.send(text: text, photos: photos, userId: widget.userId)
        : await chat.sendDirect(
            peerId: widget.peerId!,
            offerId: widget.offerId,
            text: text,
            photos: photos,
          );
    if (!mounted) return;
    switch (result) {
      case Sent():
        break;
      case Queued():
        showMessage(context, 'Hors ligne : envoyé au retour de la connexion');
      case Rejected(:final message):
        showMessage(context, message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.userId;
    final peerId = widget.peerId;
    final items = peerId != null
        ? ref.watch(directFeedProvider(peerId))
        : userId == null
        ? ref.watch(
            widget.messagesOnly
                ? userMessagesFeedProvider
                : userChatFeedProvider,
          )
        : ref.watch(adminChatFeedProvider(userId));
    // Nouveau message reçu pendant que la conversation est ouverte.
    ref.listen(chatMessagesProvider, (_, _) => _markRead());
    ref.listen(directMessagesProvider, (_, _) => _markRead());

    return Column(
      children: [
        Expanded(
          child: items.isEmpty
              ? _Empty(admin: userId != null, direct: peerId != null)
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final older = index + 1 < items.length
                        ? items[index + 1]
                        : null;
                    final newDay =
                        older == null ||
                        !DateUtils.isSameDay(older.at, item.at);
                    return Column(
                      children: [
                        if (newDay) _DaySeparator(item.at),
                        _Bubble(item: item),
                      ],
                    );
                  },
                ),
        ),
        _Composer(
          text: _text,
          photos: _photos,
          canSend: _canSend,
          onAttach: _attach,
          onRemove: (index) => setState(() => _photos.removeAt(index)),
          onSend: _send,
        ),
      ],
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');
String _time(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

class _DaySeparator extends StatelessWidget {
  const _DaySeparator(this.day);

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final date = DateUtils.dateOnly(day);
    final label = date == today
        ? 'Aujourd’hui'
        : date == today.subtract(const Duration(days: 1))
        ? 'Hier'
        : '${_two(day.day)}/${_two(day.month)}/${day.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: ShapeDecoration(
            color: AppColors.border,
            shape: const StadiumBorder(),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final mine = item.mine;
    final foreground = mine ? Colors.white : AppColors.text;
    final muted = mine ? Colors.white70 : AppColors.textMuted;

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width * 0.75).clamp(0, 460),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: mine
            ? AppColors.primary
            : item.system
            ? AppColors.primarySoft
            : AppColors.surface,
        border: mine ? null : Border.all(color: AppColors.border),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 4),
          bottomRight: Radius.circular(mine ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine && item.senderName != null)
            Text(
              item.senderName!,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          if (item.title != null)
            Text(
              item.title!,
              style: TextStyle(fontWeight: FontWeight.w700, color: foreground),
            ),
          if (item.photosCount > 0 || item.localPhotos.isNotEmpty) ...[
            const SizedBox(height: 4),
            _Photos(item: item),
          ],
          if (item.body != null && item.body!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(item.body!, style: TextStyle(color: foreground)),
            ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _time(item.at),
                style: TextStyle(fontSize: 10, color: muted),
              ),
              if (mine) ...[
                const SizedBox(width: 4),
                Icon(
                  item.error != null
                      ? Icons.error_outline
                      : item.pending
                      ? Icons.schedule
                      : item.read
                      ? Icons.done_all
                      : Icons.done,
                  size: 13,
                  color: item.error != null ? Colors.amberAccent : muted,
                ),
              ],
            ],
          ),
          if (item.link != null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Voir le détail ›',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
          if (item.pending)
            Text(
              'En attente d’envoi',
              style: TextStyle(fontSize: 10, color: muted),
            ),
          if (item.error != null)
            Text(
              'Non envoyé : ${item.error}',
              style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[
            // Autre utilisateur : ses initiales ; sinon l'équipe Partage+.
            if (item.direct)
              ProfileAvatar(name: item.senderName ?? '?', size: 28)
            else
              CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.primarySoft,
                foregroundColor: AppColors.primary,
                child: Icon(
                  item.system ? Icons.eco_outlined : Icons.support_agent,
                  size: 16,
                ),
              ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: item.link == null
                ? bubble
                : GestureDetector(
                    onTap: () => context.push(item.link!),
                    child: bubble,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Images d'un message : locales (pas encore envoyé) ou téléchargées.
class _Photos extends StatelessWidget {
  const _Photos({required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final count = item.localPhotos.isNotEmpty
        ? item.localPhotos.length
        : item.photosCount;
    final size = count == 1 ? 200.0 : 110.0;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (var i = 0; i < count; i++)
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox.square(
              dimension: size,
              child: item.localPhotos.isNotEmpty
                  ? _Zoomable(bytes: item.localPhotos[i])
                  : _RemotePhoto(
                      messageId: item.messageId!,
                      position: i,
                      direct: item.direct,
                    ),
            ),
          ),
      ],
    );
  }
}

class _RemotePhoto extends ConsumerWidget {
  const _RemotePhoto({
    required this.messageId,
    required this.position,
    required this.direct,
  });

  final int messageId;
  final int position;
  final bool direct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(
      messagePhotoProvider((messageId, position, direct)),
    );
    return switch (photo) {
      AsyncData(value: final bytes?) => _Zoomable(bytes: bytes),
      AsyncLoading() => const ColoredBox(
        color: AppColors.background,
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      _ => InkWell(
        onTap: () =>
            ref.invalidate(messagePhotoProvider((messageId, position, direct))),
        child: const ColoredBox(
          color: AppColors.background,
          child: Center(
            child: Tooltip(
              message: 'Image indisponible hors ligne : toucher pour réessayer',
              child: Icon(
                Icons.image_not_supported_outlined,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ),
      ),
    };
  }
}

class _Zoomable extends StatelessWidget {
  const _Zoomable({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  child: Center(child: Image.memory(bytes)),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    tooltip: 'Fermer',
                    color: Colors.white,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      child: Image.memory(bytes, fit: BoxFit.cover),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.text,
    required this.photos,
    required this.canSend,
    required this.onAttach,
    required this.onRemove,
    required this.onSend,
  });

  final TextEditingController text;
  final List<ChatPhoto> photos;
  final bool canSend;
  final VoidCallback onAttach;
  final ValueChanged<int> onRemove;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (photos.isNotEmpty)
                SizedBox(
                  height: 72,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: photos.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) => Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            photos[index].bytes,
                            width: 64,
                            height: 64,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: InkWell(
                            onTap: () => onRemove(index),
                            child: const CircleAvatar(
                              radius: 10,
                              backgroundColor: Colors.black54,
                              child: Icon(
                                Icons.close,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Joindre une image',
                    onPressed: onAttach,
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: text,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Écrire un message…',
                        counterText: '',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: 'Envoyer',
                    onPressed: canSend ? onSend : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.admin, this.direct = false});

  final bool admin;
  final bool direct;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.forum_outlined,
              size: 48,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              direct
                  ? 'Posez votre question : disponibilité, heure de retrait, '
                        'accès… Vous pouvez joindre des images.'
                  : admin
                  ? 'Aucun message. Écrivez le premier.'
                  : 'Vos notifications et vos échanges avec l’équipe '
                        'Partage+ s’afficheront ici.\nUne question ? '
                        'Écrivez-nous, vous pouvez joindre des images.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
