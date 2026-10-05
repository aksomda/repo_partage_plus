# Partage+ (Repas Partage Plus)

Application anti-gaspillage alimentaire : commerçants, restaurateurs et
particuliers publient leurs invendus et surplus (don gratuit ou prix réduit),
bénéficiaires et associations les réservent puis les retirent avec un code ou
un QR code. L'application mesure l'impact (nourriture sauvée, CO₂ évité, repas)
et fonctionne hors ligne.

| Partie | Dossier | Technologies |
|---|---|---|
| Application | `lib/` | Flutter (Android, iOS, web, Windows), Riverpod, go_router, sembast |
| API | `server/` | Node.js (Express 5), MySQL |
| IA | `functions/` | Cloud Function Firebase, RodiumAI |
| Services | Firebase | Authentication, Firestore (copie de secours), Cloud Messaging, extension e-mail |

## Démarrage rapide

Prérequis : Flutter 3.44 (Dart 3.12), Node.js 22, MySQL 8 (WAMP en local).

```bash
# API : voir server/README.md pour le détail
cd server
cp .env.example .env
npm install
npm run db:migrate
npm run db:seed          # comptes de démo, mot de passe : Demo1234!
npm run dev              # http://localhost:3000

# Application (autre terminal, à la racine)
flutter pub get
flutter run              # émulateur Android : l'API est vue en 10.0.2.2:3000
```

Téléphone branché (USB ou ADB sans fil) : lancer `adb reverse tcp:3000 tcp:3000`
puis la configuration « Téléphone (USB, API locale) » de `.vscode/launch.json`.
Autre serveur : `flutter run --dart-define=API_BASE_URL=https://…/api`.

## Vérifier avant de proposer une modification

Ce sont les contrôles de la CI (`.github/workflows/ci.yml`) :

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
cd server && npm test        # base repas_partage_test recréée à chaque fois
cd functions && npm test
```

## Documentation

| Sujet | Fichier |
|---|---|
| API, routes, comptes de démo | [server/README.md](server/README.md) |
| Firebase (Auth, Firestore, e-mails) | [docs/FIREBASE.md](docs/FIREBASE.md) |
| Mode hors ligne | [docs/HORS_LIGNE.md](docs/HORS_LIGNE.md) |
| Recommandations et IA | [docs/IA.md](docs/IA.md) |
| Mise en ligne | [docs/DEPLOIEMENT.md](docs/DEPLOIEMENT.md) |
| Scénario de démonstration | [docs/DEMO.md](docs/DEMO.md) |

## Architecture

```text
lib/
  main.dart, app.dart        démarrage, thème, routeur
  core/                      code partagé par tous les modules
    network/                 client HTTP, adresses de l'API
    offline/                 file d'actions, synchronisation, données locales
    router/                  routes (app_routes.dart) et navigation
    storage/                 base locale (sembast)
    theme/, widgets/         thème et composants communs
  features/<module>/         un dossier par fonctionnalité
    data/                    dépôts (API, base locale) et providers Riverpod
    domain/                  règles métier sans interface (calculs, formats)
    presentation/            écrans, et widgets/ pour leurs composants
```

Modules : `auth`, `offers`, `discovery`, `reservations`, `pickup`,
`notifications`, `impact`, `recommendations`, `favorites`, `admin`.

Principes :
- **Hors ligne d'abord** : les écrans lisent la copie locale ; une action
  passe par la file (`SyncController.submit`) et part au retour du réseau.
- **MySQL est la référence** ; Firestore n'en est qu'une copie de secours.
- **Une route = une constante** de `AppRoutes` : jamais de chemin écrit en dur.

## Conventions de nommage

### Dart / Flutter

| Élément | Convention | Exemple |
|---|---|---|
| Fichier, dossier | `snake_case` | `my_offers_screen.dart` |
| Classe, enum, typedef | `UpperCamelCase` | `OffersRepository`, `PickupSlot` |
| Variable, fonction, paramètre | `lowerCamelCase` | `offerSlots()`, `pickupStart` |
| Membre privé | préfixe `_` | `_submit()`, `_OfferTile` |
| Provider Riverpod | nom + `Provider` | `myOffersProvider` |
| Écran | suffixe `Screen` | `ProfileScreen` (`profile_screen.dart`) |
| Dépôt | suffixe `Repository` | `GuestRepository` |
| Constante | `lowerCamelCase` | `maxPickupSlots` |

- Libellés, messages et commentaires **en français** ; identifiants en anglais.
- Un commentaire `///` explique **pourquoi** (règle métier, cas limite), pas ce
  que le code dit déjà.
- Le code est formaté par `dart format` et doit passer `flutter analyze` sans
  avertissement.

### API (`server/`)

| Élément | Convention | Exemple |
|---|---|---|
| Fichier | `snake_case.js` | `login_attempts.js` |
| Route | nom au pluriel, `kebab-case` | `/api/offers/:id/slots`, `/api/auth/release-orphan` |
| Champ JSON, colonne MySQL | `snake_case` | `pickup_start`, `quantity_available` |
| Table MySQL | `snake_case` au pluriel | `offer_slots`, `device_tokens` |
| Variable d'environnement | `MAJUSCULES_SOULIGNÉES` | `MAIL_REPLY_TO` |

Toute modification du schéma passe par `server/src/db/schema.sql` **et**
`migrate.js` (colonnes ajoutées sur les bases existantes).

## Conventions Git

### Branches

| Branche | Rôle |
|---|---|
| `main` | Version en ligne. Un push déploie (Render, GitHub Pages). Jamais de commit direct. |
| `dev` | Intégration de l'équipe. Reçoit les pull requests, contrôlées par la CI. |
| `features-<nom>` | Branche de travail de chaque membre (ex. `features-aksomda`). |

Déroulement :
1. Mettre sa branche à jour : `git pull origin dev`.
2. Travailler et commiter sur `features-<nom>`.
3. Ouvrir une pull request **vers `dev`** ; elle n'est fusionnée que si la CI
   est verte.
4. `dev` est fusionnée dans `main` pour une mise en ligne.

### Messages de commit

Format : `<type>(T-xx): description en français`, où `T-xx` est la tâche du
tableau de suivi.

| Type | Usage |
|---|---|
| `feat` | Nouvelle fonctionnalité |
| `fix` | Correction de bogue |
| `refactor` | Réorganisation sans changement de comportement |
| `test` | Tests ajoutés ou corrigés |
| `docs` | Documentation |
| `chore` | Dépendances, configuration, outillage |

Exemples :

```text
feat(T-23): créneaux de retrait multiples choisis à la réservation
fix(T-17): libérer un compte Firebase orphelin lors de l'inscription
docs(T-10): conventions Git dans le README
```

Règles :
- Un commit = un changement cohérent ; pas de fichiers sans rapport.
- Jamais de secret : `server/.env` et les comptes de service Firebase sont
  ignorés par `.gitignore` (voir `server/.env.example` pour les clés attendues).
- Les versions des dépendances du `pubspec.yaml` sont figées : toute mise à
  jour passe par une pull request vers `dev`.
