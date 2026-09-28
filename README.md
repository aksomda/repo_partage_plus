# Repas Partage Plus

Application anti-gaspillage : des donateurs publient leurs invendus alimentaires, des bénéficiaires
et associations les réservent à proximité et viennent les retirer.

| Partie | Techno | Dossier |
|---|---|---|
| Application mobile et web | Flutter (go_router, Riverpod, Dio, flutter_map, geolocator, notifications locales) | `lib/` |
| API | Node.js, Express, MySQL | [`server/`](server/README.md) |

## Démarrer en local

```bash
# 1. API (WAMP démarré)
cd server
cp .env.example .env
npm install
npm run db:migrate && npm run db:seed
npm run dev

# 2. Application (dans un autre terminal, à la racine)
flutter pub get
flutter run -d chrome        # ou un émulateur Android
```

L'application appelle `http://localhost:3000/api` (web) ou `http://10.0.2.2:3000/api` (émulateur Android).
Pour une autre API : `flutter run --dart-define=API_BASE_URL=https://…/api`.

## Organisation du code Flutter

```text
lib/
  core/        router, client HTTP, widgets communs
  features/    une feature par dossier : data/ domain/ presentation/
    admin auth discovery impact notifications offers pickup recommendations reservations
```

## Travail en équipe

- Une branche par personne (`features-<pseudo>`), PR vers `dev`, relue par un autre membre.
- La CI (lint, tests Flutter et API, builds APK et web) doit être verte avant de merger.
- `dev` est mergée dans `main` pour mettre en ligne.

## Documentation

- [API et base de données](server/README.md)
- [Mode hors ligne](docs/HORS_LIGNE.md) : copie locale, file d'attente, synchronisation
- [Mise en ligne](docs/DEPLOIEMENT.md) : Render, Railway, GitHub Pages, APK
- [Répétition de la démo](docs/DEMO.md)
