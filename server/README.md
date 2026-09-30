# API Repas Partage Plus

API REST Node.js (Express 5) + MySQL qui sauvegarde les données de l'application Flutter.

## Lancer en local (WAMP)

1. Démarrer WAMP (MySQL doit écouter sur le port 3306).
2. Dans `server/` :

```bash
cp .env.example .env      # adapter DB_USER / DB_PASSWORD si besoin
npm install
npm run db:migrate        # crée la base repas_partage et ses tables
npm run db:seed           # données de démo (mot de passe : Demo1234!)
npm run dev               # http://localhost:3000, redémarre à chaque modification
```

Vérifier : <http://localhost:3000/health> doit répondre `{"status":"ok"}`.

| Script | Rôle |
|---|---|
| `npm run dev` | Serveur avec rechargement automatique |
| `npm start` | Serveur sans rechargement |
| `npm run db:migrate` | Crée/actualise les tables (sans perte de données) |
| `npm run db:seed` | Ajoute les données de démo si la base est vide |
| `npm run db:seed -- --fresh` | **Efface toutes les données** puis recrée la démo |
| `npm test` | Tests de l'API sur une base `repas_partage_test` recréée à chaque fois |

## Authentification

Mot de passe géré par **Firebase Auth**, profil dans MySQL, code d'activation
envoyé par e-mail par l'API : configuration et schéma dans
[`docs/FIREBASE.md`](../docs/FIREBASE.md).

| Route | Rôle |
|---|---|
| `GET /api/actors` | Acteurs proposés à l'inscription |
| `POST /api/auth/register` | Profil + jeton Firebase → compte `pending`, code envoyé |
| `POST /api/auth/verify-email` | E-mail + code → compte actif, renvoie la session |
| `POST /api/auth/resend-code` | Nouveau code (1 par minute) |
| `POST /api/auth/firebase` | Jeton Firebase → session (compte actif uniquement) |
| `POST /api/auth/login` | Mot de passe MySQL : comptes de démo seulement |
| `GET/POST/PUT/DELETE /api/admin/actors` | Configuration des acteurs |
| `PATCH /api/admin/users/:id/status` | Désactivation / réactivation (répercutée sur Firebase) |

## Utilisation sans compte (invités)

Consulter, rechercher, publier et réserver sont possibles sans compte.
L'invité donne nom, prénom et téléphone ; l'API renvoie un `guest_token`
(une seule fois, stocké haché dans `guest_tokens`) que l'application garde
pour suivre ou annuler depuis l'appareil (en-tête `X-Guest-Token`).
Limite : 10 publications et 20 réservations sans compte par heure et par IP.

| Route | Rôle |
|---|---|
| `GET /api/sync/public` | Catalogue public : catégories et offres disponibles |
| `POST /api/offers` | Avec jeton de session, ou `guest: {first_name, last_name, phone}` |
| `GET` / `DELETE /api/offers/:id` + `X-Guest-Token` | Voir (même en modération) / retirer son offre d'invité |
| `POST /api/reservations` | Avec session ou `guest` ; `payment_reference` obligatoire si l'offre est payante |
| `GET /api/reservations/guest/:id` + `X-Guest-Token` | Suivre sa réservation d'invité (code de retrait inclus) |
| `PATCH /api/reservations/:id/cancel` + `X-Guest-Token` | Annuler sa réservation d'invité |

**Paiement hors application** : `offers.price` (F CFA par unité, 0 = gratuit)
et `payment_info` (ex. « Orange Money 70 00 00 00 »). L'acheteur paie puis
saisit la référence de la transaction (`reservations.payment_reference`) ;
le publieur la voit dans les réservations reçues avant de confirmer.

**Offre publiée par un invité** : personne ne peut la confirmer dans l'app,
les réservations sont confirmées d'office et le retrait se convient par
téléphone (`contact_phone`). Tous les acteurs connectés (sauf admin) publient.

## Comptes de démo

Mot de passe commun : `Demo1234!`

| Email | Rôle |
|---|---|
| `admin@demo.local` | Administrateur |
| `commerce@demo.local` | Donateur (boulangerie) |
| `restaurant@demo.local` | Donateur (restaurant) |
| `beneficiaire@demo.local` | Bénéficiaire |
| `association@demo.local` | Association validée |
| `association2@demo.local` | Association en attente de validation |

## Base de données

Schéma complet : [`src/db/schema.sql`](src/db/schema.sql).

| Table | Contenu |
|---|---|
| `actors` | Acteurs proposés à l'inscription (particulier, commerçant…), configurés par l'admin, avec leurs droits |
| `users` | Comptes : nom, prénom, sexe, âge, téléphone, acteur, droits, position, statut `pending` → `active` / `suspended` |
| `email_otps` | Codes d'activation envoyés par e-mail (hachés, 10 min, 5 essais) |
| `associations` | Informations des associations et statut de validation |
| `categories` | Catégories d'aliments |
| `impact_factors` | Facteurs par catégorie : kg de CO2 évités et repas par kg sauvé |
| `offers` | Offres de dons : quantité, poids, DLC, créneau et lieu de retrait, statut de modération |
| `reservations` | Réservations, code de retrait à 6 chiffres, statut |
| `notifications` | Notifications in-app (confirmation, rappel de retrait, DLC proche…) |

Cycle d'une offre : `pending` (en modération) → `published` → `reserved` (épuisée) → `completed` (tout retiré).
Autres fins possibles : `rejected`, `cancelled`, `expired`.

Cycle d'une réservation : `pending` → `confirmed` (par le donateur) → `picked_up` (code validé), ou `cancelled`.

## Routes

Préfixe : `/api`. Authentification : en-tête `Authorization: Bearer <token>` reçu à la connexion.
Les erreurs renvoient `{ "error": "message", "details": [...] }`.

### Mode hors ligne

| Méthode | Route | Accès | Rôle |
|---|---|---|---|
| GET | `/sync` | connecté | Instantané complet (profil, catégories, offres disponibles, réservations, notifications, impact, données admin) stocké par l'app |

Toute requête `POST`/`PUT`/`PATCH`/`DELETE` peut porter un en-tête `Idempotency-Key` (8 à 64 caractères).
Rejouée avec la même clé, elle n'est pas réappliquée : la réponse d'origine est renvoyée avec
l'en-tête `Idempotent-Replayed: true`. Voir [docs/HORS_LIGNE.md](../docs/HORS_LIGNE.md).

### Authentification et profil

| Méthode | Route | Accès | Rôle |
|---|---|---|---|
| POST | `/auth/register` | public | Inscription (`role` : donor, beneficiary, association ; objet `association` requis pour une association) |
| POST | `/auth/login` | public | Connexion → `{ token, user }` |
| GET | `/auth/me` | connecté | Profil (et association le cas échéant) |
| PATCH | `/users/me` | connecté | Modifier nom, téléphone, position |
| PUT | `/users/me/password` | connecté | Changer de mot de passe |

### Offres

| Méthode | Route | Accès | Rôle |
|---|---|---|---|
| GET | `/offers?category_id&q&limit&offset` | public | Offres disponibles |
| GET | `/offers/nearby?lat&lng&radius_km&category_id` | public | **Offres à proximité**, triées par distance (`distance_km`) |
| GET | `/offers/expiring-soon?days=1` | public | **DLC proche** : offres qui expirent sous `days` jours |
| GET | `/offers/mine` | donateur | Mes offres, tous statuts |
| GET | `/offers/:id` | public | Détail d'une offre |
| POST | `/offers` | donateur | Publier une offre (part en modération) |
| PUT | `/offers/:id` | donateur | Modifier (si aucune réservation) ; repart en modération |
| DELETE | `/offers/:id` | donateur | Retirer l'offre ; annule les réservations en cours |

### Réservations et retrait

| Méthode | Route | Accès | Rôle |
|---|---|---|---|
| POST | `/reservations` | bénéficiaire, association validée | Réserver `{ offer_id, quantity }` → reçoit `pickup_code` |
| GET | `/reservations/mine` | connecté | Mes réservations |
| GET | `/reservations/received` | donateur | Réservations reçues sur mes offres |
| GET | `/reservations/:id` | concerné ou admin | Détail |
| PATCH | `/reservations/:id/confirm` | donateur | **Confirmer la réservation** (notifie le bénéficiaire) |
| PATCH | `/reservations/:id/cancel` | bénéficiaire ou donateur | Annuler (rend la quantité à l'offre) |
| POST | `/reservations/:id/pickup` | donateur | Valider le retrait avec `{ pickup_code }` |

### Notifications, impact, recommandations

| Méthode | Route | Accès | Rôle |
|---|---|---|---|
| GET | `/notifications?unread=true&after_id` | connecté | Mes notifications (`after_id` : seulement les nouvelles) |
| GET | `/notifications/unread-count` | connecté | Nombre de non lues |
| PATCH | `/notifications/:id/read` | connecté | Marquer comme lue |
| PATCH | `/notifications/read-all` | connecté | Tout marquer comme lu |
| GET | `/impact/me` | connecté | Mon impact : retraits, kg sauvés, CO2 évité, repas |
| GET | `/impact/global` | public | Impact de toute la plateforme |
| GET | `/recommendations` | connecté | Offres recommandées (catégories préférées, distance, DLC) |
| GET | `/categories` | public | Catégories avec leurs facteurs |
| GET | `/factors` | public | Facteurs d'impact |

### Administration (rôle admin)

| Méthode | Route | Rôle |
|---|---|---|
| GET | `/admin/stats` | Compteurs du tableau de bord |
| GET | `/admin/offers?status=pending` | Offres à modérer |
| PATCH | `/admin/offers/:id/moderation` | `{ decision: approve \| reject, reason }` (motif obligatoire si refus) |
| GET | `/admin/users?role&status&q` | Comptes |
| PATCH | `/admin/users/:id/status` | `{ status: active \| suspended, reason }` |
| GET | `/admin/associations?status=pending` | Associations à valider |
| PATCH | `/admin/associations/:id/review` | `{ decision: approve \| reject, reason }` |
| POST / PUT / DELETE | `/admin/categories[/:id]` | Gérer les catégories `{ name, icon }` |
| POST / PUT / DELETE | `/admin/factors[/:id]` | Gérer les facteurs `{ category_id, co2_kg_per_kg, meals_per_kg, source }` |
| POST | `/admin/jobs/run` | Lancer les tâches planifiées maintenant |

### Tâches planifiées

Toutes les `JOBS_INTERVAL_MINUTES` (15 par défaut), le serveur :

- envoie le **rappel de retrait** aux réservations confirmées dont le créneau commence dans moins de 2 h ;
- signale les offres dont la **DLC** tombe aujourd'hui ou demain (au donateur et aux bénéficiaires concernés) ;
- passe en `expired` les offres dont la DLC ou le créneau de retrait est dépassé.

Elles peuvent aussi être déclenchées par `POST /api/jobs/run` avec l'en-tête `X-Jobs-Token: <JOBS_TOKEN>` (cron externe, voir [docs/DEPLOIEMENT.md](../docs/DEPLOIEMENT.md)).

L'application Flutter récupère ces notifications via `GET /notifications?after_id=…` et les affiche avec `flutter_local_notifications`.
