import 'package:uuid/uuid.dart';

/// Action faite dans l'application (réserver, publier, confirmer…) et pas
/// encore acceptée par le serveur. Envoyée avec un en-tête Idempotency-Key :
/// la renvoyer après une coupure ne l'applique jamais deux fois.
class PendingAction {
  PendingAction({
    required this.kind,
    required this.method,
    required this.path,
    required this.label,
    this.body,
    this.targetId,
    String? key,
    DateTime? createdAt,
    this.localId,
    this.attempts = 0,
    this.error,
  }) : key = key ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now().toUtc();

  /// Identifiant dans la file locale (null avant enregistrement).
  final int? localId;

  /// Clé d'idempotence envoyée au serveur.
  final String key;

  /// Type d'action, ex. `reservation.create`, `offer.moderate`.
  final String kind;
  final String method;
  final String path;
  final Map<String, Object?>? body;

  /// Élément serveur concerné (id de réservation, d'offre…), si existant.
  final int? targetId;

  /// Description lisible, affichée à l'utilisateur.
  final String label;
  final DateTime createdAt;
  final int attempts;

  /// Motif du refus du serveur ; non null = action refusée, plus renvoyée.
  final String? error;

  bool get isRejected => error != null;

  PendingAction copyWith({int? localId, int? attempts, String? error}) {
    return PendingAction(
      localId: localId ?? this.localId,
      key: key,
      kind: kind,
      method: method,
      path: path,
      body: body,
      targetId: targetId,
      label: label,
      createdAt: createdAt,
      attempts: attempts ?? this.attempts,
      error: error ?? this.error,
    );
  }

  Map<String, Object?> toMap() => {
    'key': key,
    'kind': kind,
    'method': method,
    'path': path,
    'body': body,
    'target_id': targetId,
    'label': label,
    'created_at': createdAt.toIso8601String(),
    'attempts': attempts,
    'error': error,
  };

  factory PendingAction.fromMap(int localId, Map<String, Object?> map) {
    return PendingAction(
      localId: localId,
      key: map['key']! as String,
      kind: map['kind']! as String,
      method: map['method']! as String,
      path: map['path']! as String,
      body: (map['body'] as Map?)?.cast<String, Object?>(),
      targetId: map['target_id'] as int?,
      label: map['label']! as String,
      createdAt: DateTime.parse(map['created_at']! as String),
      attempts: map['attempts'] as int? ?? 0,
      error: map['error'] as String?,
    );
  }
}
