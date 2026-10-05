# Mode hors ligne

L'application fonctionne sans réseau : elle garde une copie locale des données et met les actions
en file d'attente. Au retour du réseau, tout est envoyé au serveur, qui accepte ou refuse chaque action.

## Ce qui marche hors ligne

| Fonction | Hors ligne |
|---|---|
| Ouvrir l'app, rester connecté | ✅ session gardée sur l'appareil |
| Première connexion / inscription | ❌ réseau requis |
| Voir les offres, offres à proximité, DLC proche | ✅ calculé sur l'appareil à partir de la dernière copie |
| Réserver | ✅ « en attente d'envoi », acceptée ou refusée à la synchronisation |
| Voir mes réservations et **mon code de retrait** | ✅ |
| Confirmer une réservation, valider un retrait (donateur) | ✅ en file ; un code faux revient en « Action refusée ». L'heure réelle du retrait est envoyée (en-tête `X-Action-At`) : le créneau est vérifié à cette heure-là |
| Publier / modifier / retirer une offre | ✅ en file ; publiée dès l'envoi (l'administrateur retire après coup les abus) |
| Modérer offres et comptes, valider associations, catégories, facteurs (admin) | ✅ en file |
| Rappel de retrait, alerte DLC proche | ✅ programmés sur le téléphone (Android/iOS) |
| Notifications, impact | ✅ dernière copie ; « lu » enregistré localement |
| Fond de carte | ✅ zones déjà consultées (cache de tuiles de 300 Mo, servi « hors ligne d'abord ») ; zone jamais vue : cases vides et bandeau, la liste reste disponible. Pas de téléchargement de zones à l'avance : la politique d'usage des tuiles OpenStreetMap interdit le téléchargement en masse |
| Favoris (offres, recherches enregistrées) | ✅ gardés sur l'appareil, sans compte aussi ; recopiés dans le compte au retour du réseau |
| Profil, préférences, notifications push | ✅ modifications en file ; changement de mot de passe : réseau requis |
| Risque de gaspillage de mes offres | ✅ dernière copie ; conseil rédigé par l'IA : réseau requis |

Sur le **web**, tout fonctionne sauf les notifications système : elles restent visibles dans l'écran Notifications.

## Fonctionnement

```text
 Écran ──lit──▶ providers (lib/features/*/data) ──lit──▶ base locale (sembast)
   │                                                        ▲
   └─action──▶ Repository.xxx() ──▶ file d'attente ─────────┤
                                        │                   │
                             SyncController (réseau revenu, │
                             toutes les 2 min, après action)│
                                        │                   │
                                        ▼                   │
                       1. envoie chaque action, dans l'ordre│
                          (en-tête Idempotency-Key)         │
                       2. GET /api/sync ────────────────────┘
                       3. reprogramme les rappels locaux
```

- **Lecture** : les écrans lisent *toujours* la base locale, jamais l'API directement. En ligne,
  elle est rafraîchie automatiquement ; hors ligne, elle montre la dernière copie.
- **Écriture** : chaque action passe par la file ([`sync_controller.dart`](../lib/core/offline/sync_controller.dart)).
  En ligne, elle part immédiatement ; hors ligne, elle attend.
- **Pas de doublon** : chaque action porte une clé unique (`Idempotency-Key`). Si la connexion coupe
  pendant l'envoi, l'app renvoie la même clé et le serveur renvoie la réponse déjà donnée au lieu de
  refaire l'action (réservation comptée une seule fois).
- **Ordre garanti** : les actions partent dans l'ordre où elles ont été faites ; à la première coupure,
  l'envoi s'arrête et reprend plus tard au même endroit.
- **Refus** : si le serveur refuse (offre épuisée entre-temps, code de retrait faux…), l'action est marquée
  refusée, l'utilisateur reçoit une notification « Action refusée » avec le motif, et elle n'est plus renvoyée.

## Utiliser dans un écran

```dart
class ReservationButton extends ConsumerWidget {
  const ReservationButton({super.key, required this.offer});
  final Json offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () async {
        final result = await ref.read(reservationsRepositoryProvider).reserve(
          offerId: offer['id'] as int,
          offerTitle: offer['title'] as String,
        );
        final message = switch (result) {
          Sent() => 'Réservation envoyée',
          Queued() => 'Hors ligne : réservation enregistrée, envoi au retour du réseau',
          Rejected(:final message) => 'Refusée : $message',
        };
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
        }
      },
      child: const Text('Réserver'),
    );
  }
}
```

Lire les données :

```dart
final offers = ref.watch(nearbyOffersProvider(NearbyQuery(lat, lng, radiusKm: 5)));
final reservations = ref.watch(myReservationsProvider); // status 'pending_sync' si pas encore envoyée
final pending = ref.watch(waitingActionsProvider);      // actions en attente
final refused = ref.watch(rejectedActionsProvider);     // actions refusées à afficher
```

Un élément en attente porte `local: true` (pas encore d'id serveur) ou `pending_actions: [...]`
(ex. `['reservation.confirm']`) : l'afficher avec un badge « en attente d'envoi ».

## Fichiers

| Fichier | Rôle |
|---|---|
| [`core/storage/local_store.dart`](../lib/core/storage/local_store.dart) | Base locale : session, copie des données, file |
| [`core/offline/pending_action.dart`](../lib/core/offline/pending_action.dart) | Une action en attente |
| [`core/offline/outbox.dart`](../lib/core/offline/outbox.dart) | La file d'attente |
| [`core/offline/sync_service.dart`](../lib/core/offline/sync_service.dart) | Envoi de la file + récupération de `/api/sync` |
| [`core/offline/sync_controller.dart`](../lib/core/offline/sync_controller.dart) | Quand synchroniser ; `submit()` pour les actions |
| [`core/offline/offline_banner.dart`](../lib/core/offline/offline_banner.dart) | Bandeau « Hors ligne » / « en attente » |
| [`core/notifications/`](../lib/core/notifications/) | Rappels programmés sur l'appareil |
| `features/*/data/*_repository.dart` | Données et actions de chaque feature |

Côté serveur : [`GET /api/sync`](../server/src/routes/sync.js) et le middleware
[`idempotency.js`](../server/src/http/idempotency.js).

## Tester

1. Se connecter une fois avec le réseau.
2. Passer le téléphone en **mode avion** (ou, sur le web, DevTools → Network → *Offline*).
3. Réserver, confirmer, etc. : le bandeau indique « N action(s) seront envoyées ».
4. Réactiver le réseau : le bandeau affiche « Synchronisation… » puis disparaît.

Tests automatiques : `flutter test test/offline_test.dart` et `npm test` (dans `server/`).
