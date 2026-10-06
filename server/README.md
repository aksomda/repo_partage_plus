# README.md - Documentation en français

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
| `npm run dev` | Met à jour les tables, puis serveur avec rechargement automatique |
| `npm start` | Met à jour les tables, puis serveur sans rechargement |
| `npm run db:migrate` | Crée/actualise les tables (sans perte de données) |
| `npm run db:seed` | Ajoute les données de démo si la base est vide |
| `npm run db:seed -- --fresh` | **Efface toutes les données** puis recrée la démo |
| `npm test` | Tests de l'API sur une base `repas_partage_test` recréée à chaque fois |

## Authentification

Mot de passe géré par **Firebase Auth**, profil dans MySQL, code d'activation
envoyé par e-mail par l'API : configuration et schéma dans
[`docs/FIREBASE.md`](../docs/FIREBASE.md).

**Firebase injoignable, MySQL disponible** : rien n'est bloqué. Le mot de
passe est aussi gardé haché dans MySQL (à l'inscription, à chaque connexion) :
l'application se connecte alors par `POST /api/auth/login`. Les changements
faits pendant la panne (compte créé, mot de passe, e-mail vérifié,
désactivation) sont notés (`users.firebase_sync_at`) puis recopiés dans
Firebase en arrière-plan, au démarrage et à chaque passage des tâches
planifiées, jusqu'à réussite (compte de service requis).

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

**Offre publiée par un invité** : elle ne se réserve pas (`POST /api/reservations`
répond 409, `details.code = guest_offer_call`) ; on appelle le donateur au
`contact_phone` pour convenir du retrait. Les offres publiées par un compte se
réservent avec ou sans compte. Tous les acteurs connectés (sauf admin) publient.

## Comptes de démo

Mot de passe commun : `Demo1234!`

| Email | Rôle |
|---|---|
| `admin@demo.local` | Administrateur |
| `commerce@demo.local` | Donateur (boulangerie) |
| `restaurant@demo.local` | Donateur (restaurant) |
| `beneficiaire@demo.local` | Bénéficiaire |
| `association@demo.local` | Association (Solidarité Plus) |
| `association2@demo.local` | Association (Entraide Quartier) |

## Base de données

Schéma complet : [`src/db/schema.sql`](src/db/schema.sql).

| Table | Contenu |
|---|---|
| `actors` | Acteurs proposés à l'inscription (particulier, commerçant…), configurés par l'admin, avec leurs droits |
| `users` | Comptes : nom, prénom, sexe, âge, téléphone, acteur, droits, position, statut `pending` → `active` / `suspended` |
| `email_otps` | Codes d'activation envoyés par e-mail (hachés, 10 min, 5 essais) |
| `associations` | Informations des associations (aucune validation : actives dès l'activation du compte) |
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
| POST | `/reservations` | bénéficiaire, association | Réserver `{ offer_id, quantity }` → reçoit `pickup_code` |
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
| POST | `/recommendations/offer-draft` | restaurateur | Publication express : brouillon d'offre rédigé par l'IA à partir d'une description libre (rien n'est publié) |
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


# README.md - Documentation en anglais
# Repas Partage Plus API

REST API built with **Node.js (Express 5) and MySQL**, used to store and manage data for the Flutter application.

## Running Locally with WAMP

### Prerequisites

Before starting the API:

1. Start **WAMP**. MySQL must be listening on port `3306`.
2. Make sure Node.js and npm are installed.
3. Open a terminal in the `server/` directory.

Run the following commands:

```bash
cp .env.example .env      # Adjust DB_USER / DB_PASSWORD if required
npm install
npm run db:migrate        # Creates the repas_partage database and its tables
npm run db:seed           # Loads demo data (password: Demo1234!)
npm run dev               # http://localhost:3000, automatically restarts after changes
```

### Health Check

Open:

```text
http://localhost:3000/health
```

The API is running correctly if the response is:

```json
{"status":"ok"}
```

### Available Scripts

| Script                       | Purpose                                                                            |
| ---------------------------- | ---------------------------------------------------------------------------------- |
| `npm run dev`                | Updates the database tables, then starts the server with automatic reload          |
| `npm start`                  | Updates the database tables, then starts the server without automatic reload       |
| `npm run db:migrate`         | Creates or updates database tables without deleting existing data                  |
| `npm run db:seed`            | Adds demo data if the database is empty                                            |
| `npm run db:seed -- --fresh` | **Deletes all data** and recreates the demo data                                   |
| `npm test`                   | Runs API tests against a `repas_partage_test` database recreated for each test run |

## Authentication

User passwords are managed by **Firebase Authentication**. The user profile is stored in MySQL, while the API sends the email verification code.

Firebase configuration and database schema are documented in [`docs/FIREBASE.md`](../docs/FIREBASE.md).

**Firebase unreachable, MySQL available**: nothing is blocked. The password is also kept hashed in MySQL (at registration and on each login), so the app falls back to `POST /api/auth/login`. Changes made during the outage (account created, password, email verified, suspension) are flagged (`users.firebase_sync_at`) and copied to Firebase in the background, at startup and on each scheduled job run, until they succeed (service account required).

| Route                                   | Purpose                                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `GET /api/actors`                       | Returns the user roles available during registration                                                   |
| `POST /api/auth/register`               | Creates the profile and Firebase token, sets the account to `pending`, and sends the verification code |
| `POST /api/auth/verify-email`           | Verifies the email and code, activates the account, and returns the session                            |
| `POST /api/auth/resend-code`            | Sends a new verification code, limited to one request per minute                                       |
| `POST /api/auth/firebase`               | Exchanges a Firebase token for a session; active accounts only                                         |
| `POST /api/auth/login`                  | MySQL password authentication; demo accounts only                                                      |
| `GET/POST/PUT/DELETE /api/admin/actors` | Manages available user roles                                                                           |
| `PATCH /api/admin/users/:id/status`     | Disables or reactivates a user account and synchronizes the status with Firebase                       |

## Using the API Without an Account

The following operations are available without creating an account:

* browsing offers;
* searching for offers;
* publishing an offer;
* making a reservation.

For guest access, the user provides:

* first name;
* last name;
* phone number.

The API then returns a `guest_token`. This token is returned only once and is stored as a hash in the `guest_tokens` table.

The Flutter application stores the token locally and uses it to track or cancel guest operations through the `X-Guest-Token` header.

### Guest Usage Limits

Unauthenticated users are limited to:

* **10 offers per hour per IP address**;
* **20 reservations per hour per IP address**.

| Route                                                  | Purpose                                                                                          |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| `GET /api/sync/public`                                 | Public catalog containing categories and available offers                                        |
| `POST /api/offers`                                     | Create an offer using a session token or `guest: {first_name, last_name, phone}`                 |
| `GET` / `DELETE /api/offers/:id` + `X-Guest-Token`     | View an offer, including while it is under moderation, or remove the guest's own offer           |
| `POST /api/reservations`                               | Create a reservation using a session or `guest`; `payment_reference` is required for paid offers |
| `GET /api/reservations/guest/:id` + `X-Guest-Token`    | Track a guest reservation, including its pickup code                                             |
| `PATCH /api/reservations/:id/cancel` + `X-Guest-Token` | Cancel a guest reservation                                                                       |

### Payments Outside the Application

Payment is handled outside the application.

The `offers` table contains:

```text
offers.price
offers.payment_info
```

`offers.price` represents the price in **West African CFA francs (F CFA) per unit**:

* `0` = free offer;
* a value greater than `0` = paid offer.

`payment_info` contains the payment instructions, for example:

```text
Orange Money 70 00 00 00
```

The buyer makes the payment externally and enters the transaction reference in:

```text
reservations.payment_reference
```

The donor can then view the payment reference in the received reservations before confirming the reservation.

### Offers Published by Guests

An offer published by a guest **cannot be reserved through the API**.

A request to:

```text
POST /api/reservations
```

returns HTTP `409` with:

```text
details.code = guest_offer_call
```

The beneficiary must contact the donor using the `contact_phone` associated with the offer in order to arrange the pickup.

Offers published by registered accounts can be reserved by users with or without an account.

All authenticated actors, except administrators, can publish offers.

## Demo Accounts

The common password is:

```text
Demo1234!
```

| Email                     | Role                         |
| ------------------------- | ---------------------------- |
| `admin@demo.local`        | Administrator                |
| `commerce@demo.local`     | Donor — bakery               |
| `restaurant@demo.local`   | Donor — restaurant           |
| `beneficiaire@demo.local` | Beneficiary                  |
| `association@demo.local`  | Association (Solidarité Plus) |
| `association2@demo.local` | Association (Entraide Quartier) |

## Database

The complete database schema is available in [`src/db/schema.sql`](src/db/schema.sql).

| Table            | Content                                                                                                                                      |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `actors`         | User roles available during registration, such as individuals and retailers; configured by administrators with their associated permissions  |
| `users`          | User accounts: last name, first name, gender, age, phone number, actor, permissions, location, and status `pending` → `active` / `suspended` |
| `email_otps`     | Email verification codes, stored as hashes, valid for 10 minutes, with a maximum of 5 attempts                                               |
| `associations`   | Association information (no approval: active once the account is activated)                                                                                                 |
| `categories`     | Food categories                                                                                                                              |
| `impact_factors` | Impact factors by category: kilograms of CO₂ avoided and meals per kilogram of food saved                                                    |
| `offers`         | Donation offers: quantity, weight, expiry date, pickup time slot, pickup location, and moderation status                                     |
| `reservations`   | Reservations, six-digit pickup code, and reservation status                                                                                  |
| `notifications`  | In-app notifications such as confirmations, pickup reminders, and upcoming expiry notifications                                              |

### Offer Lifecycle

The normal offer lifecycle is:

```text
pending → published → reserved → completed
```

Where:

* `pending` = awaiting moderation;
* `published` = available for reservation;
* `reserved` = all available quantity has been reserved;
* `completed` = all reserved items have been collected.

Other possible final states are:

```text
rejected
cancelled
expired
```

### Reservation Lifecycle

The normal reservation lifecycle is:

```text
pending → confirmed → picked_up
```

Where:

* `pending` = reservation submitted;
* `confirmed` = reservation confirmed by the donor;
* `picked_up` = pickup code successfully validated.

A reservation can also be:

```text
cancelled
```

## API Routes

All API endpoints use the following prefix:

```text
/api
```

Authenticated requests must include the following HTTP header:

```http
Authorization: Bearer <token>
```

The token is obtained during authentication.

### Error Format

API errors use the following structure:

```json
{
  "error": "message",
  "details": []
}
```

## Offline Mode

| Method | Route   | Access        | Purpose                                                                                                                                                                                                |
| ------ | ------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| GET    | `/sync` | Authenticated | Returns a complete snapshot containing the profile, categories, available offers, reservations, notifications, impact data, and administration data. The Flutter application stores this data locally. |

### Idempotency

Any `POST`, `PUT`, `PATCH`, or `DELETE` request can include the following header:

```http
Idempotency-Key: <key>
```

The key must contain between **8 and 64 characters**.

If the same request is sent again with the same idempotency key, the operation is not executed a second time.

Instead, the API returns the original response and adds:

```http
Idempotent-Replayed: true
```

See [`docs/HORS_LIGNE.md`](../docs/HORS_LIGNE.md) for more information about offline operation and synchronization.

## Authentication and User Profile

| Method | Route                | Access        | Purpose                                                                                                                                          |
| ------ | -------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| POST   | `/auth/register`     | Public        | User registration. `role` can be `donor`, `beneficiary`, or `association`. The `association` object is required when registering an association. |
| POST   | `/auth/login`        | Public        | Authentication → `{ token, user }`                                                                                                               |
| GET    | `/auth/me`           | Authenticated | Returns the authenticated user's profile and association information, if applicable                                                              |
| PATCH  | `/users/me`          | Authenticated | Updates the user's name, phone number, and location                                                                                              |
| PUT    | `/users/me/password` | Authenticated | Changes the user's password                                                                                                                      |

## Offers

| Method | Route                                          | Access | Purpose                                                                                   |
| ------ | ---------------------------------------------- | ------ | ----------------------------------------------------------------------------------------- |
| GET    | `/offers?category_id&q&limit&offset`           | Public | Returns available offers                                                                  |
| GET    | `/offers/nearby?lat&lng&radius_km&category_id` | Public | Returns nearby offers sorted by distance using `distance_km`                              |
| GET    | `/offers/expiring-soon?days=1`                 | Public | Returns offers whose expiry date is within the specified number of days                   |
| GET    | `/offers/mine`                                 | Donor  | Returns the authenticated donor's offers, regardless of status                            |
| GET    | `/offers/:id`                                  | Public | Returns the details of an offer                                                           |
| POST   | `/offers`                                      | Donor  | Publishes an offer; the offer enters moderation                                           |
| PUT    | `/offers/:id`                                  | Donor  | Updates an offer when there are no existing reservations; the offer returns to moderation |
| DELETE | `/offers/:id`                                  | Donor  | Removes an offer and cancels its pending reservations                                     |

## Reservations and Pickup

| Method | Route                       | Access                            | Purpose                                                                          |
| ------ | --------------------------- | --------------------------------- | -------------------------------------------------------------------------------- |
| POST   | `/reservations`             | Beneficiary, association          | Creates a reservation using `{ offer_id, quantity }` and returns a `pickup_code` |
| GET    | `/reservations/mine`        | Authenticated                     | Returns the user's reservations                                                  |
| GET    | `/reservations/received`    | Donor                             | Returns reservations received for the donor's offers                             |
| GET    | `/reservations/:id`         | Related user or administrator     | Returns reservation details                                                      |
| PATCH  | `/reservations/:id/confirm` | Donor                             | **Confirms a reservation** and notifies the beneficiary                          |
| PATCH  | `/reservations/:id/cancel`  | Beneficiary or donor              | Cancels a reservation and returns the reserved quantity to the offer             |
| POST   | `/reservations/:id/pickup`  | Donor                             | Validates the pickup using `{ pickup_code }`                                     |

## Notifications, Impact, and Recommendations

| Method | Route                                 | Access        | Purpose                                                                                       |
| ------ | ------------------------------------- | ------------- | --------------------------------------------------------------------------------------------- |
| GET    | `/notifications?unread=true&after_id` | Authenticated | Returns the user's notifications. `after_id` can be used to retrieve only newer notifications |
| GET    | `/notifications/unread-count`         | Authenticated | Returns the number of unread notifications                                                    |
| PATCH  | `/notifications/:id/read`             | Authenticated | Marks a notification as read                                                                  |
| PATCH  | `/notifications/read-all`             | Authenticated | Marks all notifications as read                                                               |
| GET    | `/impact/me`                          | Authenticated | Returns the user's impact: pickups, kilograms of food saved, CO₂ avoided, and meals           |
| GET    | `/impact/global`                      | Public        | Returns the overall impact of the platform                                                    |
| GET    | `/recommendations`                    | Authenticated | Returns recommended offers based on preferred categories, distance, and expiry date           |
| POST   | `/recommendations/offer-draft`        | Restaurateur  | Express publishing: AI-drafted offer from a free-text description (nothing is published)      |
| GET    | `/categories`                         | Public        | Returns food categories and their associated impact factors                                   |
| GET    | `/factors`                            | Public        | Returns impact factors                                                                        |

## Administration

The following endpoints require the `admin` role.

| Method              | Route                                | Purpose                                                                                      |
| ------------------- | ------------------------------------ | -------------------------------------------------------------------------------------------- |
| GET                 | `/admin/stats`                       | Returns dashboard statistics                                                                 |
| GET                 | `/admin/offers?status=pending`       | Returns offers awaiting moderation                                                           |
| PATCH               | `/admin/offers/:id/moderation`       | Uses `{ decision: approve \| reject, reason }`; a reason is required when rejecting an offer |
| GET                 | `/admin/users?role&status&q`         | Returns user accounts                                                                        |
| PATCH               | `/admin/users/:id/status`            | Uses `{ status: active \| suspended, reason }`                                               |
| POST / PUT / DELETE | `/admin/categories[/:id]`            | Manages categories using `{ name, icon }`                                                    |
| POST / PUT / DELETE | `/admin/factors[/:id]`               | Manages impact factors using `{ category_id, co2_kg_per_kg, meals_per_kg, source }`          |
| POST                | `/admin/jobs/run`                    | Immediately triggers scheduled jobs                                                          |

## Scheduled Jobs

Every `JOBS_INTERVAL_MINUTES` minutes, **15 minutes by default**, the server executes the following tasks:

* Sends a **pickup reminder** for confirmed reservations whose pickup time slot starts in less than two hours.
* Notifies donors and affected beneficiaries when an offer's **expiry date** is today or tomorrow.
* Changes offers to `expired` when their expiry date or pickup time slot has passed.

Scheduled jobs can also be triggered manually through:

```http
POST /api/jobs/run
```

The request must include:

```http
X-Jobs-Token: <JOBS_TOKEN>
```

This mechanism can be used by an external cron service.

See [`docs/DEPLOIEMENT.md`](../docs/DEPLOIEMENT.md) for deployment configuration details.

## Flutter Notification Handling

The Flutter application retrieves these notifications using:

```http
GET /notifications?after_id=…
```

The notifications are then displayed locally using the Flutter package:

```text
flutter_local_notifications
```

This mechanism allows the application to display relevant notifications even when the user is not actively viewing the application.
