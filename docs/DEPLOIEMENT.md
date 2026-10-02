# Mise en ligne

| Élément | Hébergement | Déclencheur |
|---|---|---|
| Base MySQL | Railway | Créée une fois |
| API (`server/`) | Render (plan gratuit) | Push sur `main` |
| Application web | GitHub Pages | Push sur `main` (workflow `deploy.yml`) |
| APK Android | Release GitHub | Tag `v*` (workflow `deploy.yml`) |

À faire dans cet ordre, une seule fois.

## 1. Base MySQL sur Railway

1. <https://railway.com> → **New Project** → **Deploy MySQL**.
2. Onglet **Variables** du service MySQL : copier `MYSQL_PUBLIC_URL`
   (forme `mysql://root:…@….proxy.rlwy.net:12345/railway`).

> Autre fournisseur (Aiven, etc.) : même principe, avec `DB_SSL=true` s'il impose TLS.

## 2. API sur Render

1. <https://render.com> → **New** → **Blueprint** → choisir ce dépôt GitHub.
   Render lit [`render.yaml`](../render.yaml) et crée le service `repas-partage-api`.
2. Renseigner les variables demandées :
   - `DATABASE_URL` : l'URL copiée à l'étape 1 ;
   - `CORS_ORIGINS` : `https://<utilisateur>.github.io` (ex. `https://aksomda.github.io`).
3. Au premier démarrage, `npm run start:prod` crée les tables.
4. Charger les données de démo, **une fois**, depuis un poste de l'équipe :

   ```bash
   cd server
   DATABASE_URL="mysql://…" npm run db:seed
   ```

5. Vérifier : `https://repas-partage-api.onrender.com/health` → `{"status":"ok"}`.

**Limites du plan gratuit :** le service s'endort après 15 min sans requête et met ~50 s à se réveiller ;
les tâches planifiées ne tournent pas pendant son sommeil. Pour y remédier, créer sur
<https://cron-job.org> une tâche toutes les 10 min :

- URL : `https://repas-partage-api.onrender.com/api/jobs/run`, méthode `POST` ;
- en-tête `X-Jobs-Token` : valeur de `JOBS_TOKEN` (onglet **Environment** du service Render).

Cela garde l'API éveillée et envoie les rappels de retrait / alertes DLC à l'heure.

## 3. Variable GitHub pour les builds

GitHub → **Settings → Secrets and variables → Actions → Variables** → **New repository variable** :

- `API_BASE_URL` = `https://repas-partage-api.onrender.com/api`

Utilisée par la CI et le déploiement pour construire l'APK et le web avec la bonne adresse d'API.

## 4. Application web sur GitHub Pages

1. GitHub → **Settings → Pages** → Source : **GitHub Actions**.
2. Chaque push sur `main` publie l'application sur `https://<utilisateur>.github.io/repo_partage_plus/`.
3. Lancement manuel possible : onglet **Actions** → **Déploiement** → **Run workflow**.

## 5. APK Android

Créer un tag depuis `main` :

```bash
git checkout main && git pull
git tag v1.0.0
git push origin v1.0.0
```

L'APK est attaché à la release `v1.0.0` (onglet **Releases**). À installer sur le téléphone de démo
(autoriser les « sources inconnues »).

Chaque PR vers `dev` produit aussi un APK de test dans l'onglet **Actions** (artefact `apk-release`).

> L'APK est signé avec la clé de debug : suffisant pour une démo, pas pour le Play Store.

## Build manuel (secours)

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://repas-partage-api.onrender.com/api
flutter build web --release --dart-define=API_BASE_URL=https://repas-partage-api.onrender.com/api
```
