# Répétition de la démo

Objectif : dérouler le parcours complet en **10 minutes**, sans surprise.
Faire au moins **deux répétitions complètes** avant le jour J, dont une sur le matériel réel
(téléphone avec l'APK + ordinateur avec la version web).

## Rôles

| Qui | Écran | Rôle dans la démo |
|---|---|---|
| Présentateur 1 | Téléphone (APK) | Bénéficiaire `beneficiaire@demo.local` |
| Présentateur 2 | Ordinateur (web) | Donateur `commerce@demo.local`, puis admin `admin@demo.local` |
| Présentateur 3 | — | Narration, chronomètre, plan B |

Mot de passe de tous les comptes : `Demo1234!`

## Checklist J-1

- [ ] Dernière version mergée sur `main`, CI verte
- [ ] Site web à jour sur GitHub Pages
- [ ] Tag `v…` créé, APK installé sur le téléphone de démo
- [ ] Données remises à zéro : `DATABASE_URL="mysql://…" npm run db:seed -- --fresh` (dans `server/`)
- [ ] Parcours complet déroulé une fois sur les données fraîches
- [ ] Captures d'écran / vidéo de secours enregistrées

## Checklist H-1

- [ ] Réveiller l'API : ouvrir `https://repas-partage-api.onrender.com/health` (peut prendre ~50 s)
- [ ] Téléphone chargé, Wi-Fi/4G OK, localisation activée, notifications autorisées pour l'app
- [ ] Déconnecté de tous les comptes, onglets inutiles fermés
- [ ] Partage de l'écran du téléphone testé (câble ou scrcpy)

## Scénario (10 min)

| Temps | Qui | Action | Exigence illustrée |
|---|---|---|---|
| 0:00 | P3 | Contexte : gaspillage alimentaire, principe de l'app | — |
| 1:00 | P2 | Donateur : publier « Pain du soir » (DLC demain, retrait dans 1 h) | Publication d'offre |
| 2:00 | P2 | Admin : **modérer** l'offre (valider), la liste des **catégories** et **facteurs** | Modération, catégories, facteurs |
| 4:00 | P1 | Bénéficiaire : carte des **offres à proximité**, ouvrir « Pain du soir », réserver 2 pièces | Offres à proximité |
| 5:00 | P2 | Donateur : **confirmer** la réservation | Confirmation de réservation |
| 5:30 | P1 | Notification « Réservation confirmée » + code de retrait | Notifications |
| 6:00 | P2 | Admin : lancer les tâches → **rappel de retrait** et alerte **DLC proche** reçus | Rappel de retrait, DLC proche |
| 7:00 | P1→P2 | Bénéficiaire donne le code, le donateur valide le **retrait** | Retrait |
| 8:00 | P1 | Écran **Mon impact** : kg sauvés, CO2 évité, repas | Impact |
| 8:30 | P1 | **Mode avion** : l'app reste utilisable (offres, code de retrait) ; réserver « Yaourts nature » → « en attente d'envoi ». Réactiver le réseau → la réservation part, P2 la voit | Mode hors ligne |
| 9:30 | P3 | Conclusion, questions | — |

## Plan B

| Problème | Solution |
|---|---|
| API lente / endormie | Attendre ~50 s en expliquant l'architecture ; l'avoir réveillée à H-1 |
| API en panne | L'app tourne sur sa copie locale : continuer le parcours hors ligne, les actions partiront plus tard ; sinon API en local (`server/`, `npm start`) ou vidéo de secours |
| Notification non reçue | Ouvrir l'écran Notifications (la notification est quand même en base) |
| Pas de GPS en salle | Montrer la liste des offres ou saisir une position manuellement |
| Téléphone défaillant | Faire le parcours bénéficiaire dans un 2ᵉ onglet web (navigation privée) |

## Après chaque répétition

- Noter le temps réel de chaque étape et ce qui a bloqué.
- Ouvrir une issue par bug, à corriger avant la répétition suivante.
- Remettre les données à zéro (`npm run db:seed -- --fresh`).
