# Moteur de calcul d'impact — Partage+

Cloud Functions Firebase qui calcule automatiquement l'impact généré
(produits sauvés, économies réalisées, déchets évités, CO2 évité) à
chaque fois qu'un retrait est confirmé, et alimente les données du
tableau de bord.

## Comment ça marche

1. Un(e) autre membre de l'équipe s'occupe de la **gestion des offres
   (CRUD)** et des **réservations**. Quand un bénéficiaire confirme
   avoir récupéré son produit, le champ `status` du document
   `reservations/{id}` doit passer à `"completed"`.
2. `onReservationCompleted` détecte ce changement automatiquement
   (trigger Firestore, rien à appeler côté app).
3. Le moteur va chercher l'offre correspondante, calcule l'impact,
   et met à jour les documents d'agrégats en une seule transaction.

## Schéma Firestore attendu (à partager avec l'équipe)

**`offers/{offerId}`**
| champ | type | description |
|---|---|---|
| originalPrice | number | prix initial (0 si gratuit) |
| discountedPrice | number | prix proposé sur la plateforme |
| weightKg | number | poids estimé d'une unité |
| category | string | catégorie du produit |
| ownerId | string | id du commerce/particulier |

**`reservations/{reservationId}`**
| champ | type | description |
|---|---|---|
| offerId | string | référence vers l'offre |
| userId | string | bénéficiaire |
| quantityReserved | number | quantité réservée |
| status | string | `pending` \| `confirmed` \| `completed` \| `cancelled` |

⚠️ Le calcul ne se déclenche QUE sur le passage à `"completed"`
(confirmation du retrait), jamais sur une simple réservation.

## Données produites (pour le tableau de bord / graphiques)

- `impactGlobal/summary` — compteurs pour toute la plateforme
- `impactUsers/{userId}` — compteurs personnels, total depuis le début
- `impactUserPeriods/{userId}_week_{2026-W39}` — compteurs de la semaine ISO en cours
- `impactUserPeriods/{userId}_month_{2026-09}` — compteurs du mois en cours
- `impactUserPeriods/{userId}_year_{2026}` — compteurs de l'année en cours
- `impactDaily/{YYYY-MM-DD}` — un document par jour, pour le graphique jour par jour
- `impactMonthly/{YYYY-MM}` — un document par mois, pour le graphique "Évolution de l'impact"
- `impactByCategory/{category}` — répartition par type de produit

Chaque document contient : `produitsSauves`, `economiesRealisees`,
`dechetsEvitesKg`, `emissionsCO2EviteesKg`, `updatedAt`.

Le facteur de conversion kg de déchets évités → kg de CO2 évité est
une constante `CO2_FACTOR_KG_PER_KG` (actuellement 2,5) dans
`impactEngine.ts`, à valider avec l'équipe selon la source retenue.

## Récupérer les données côté Flutter

```dart
final callable = FirebaseFunctions.instance.httpsCallable('getDashboardStats');
final result = await callable.call({'period': 'week'}); // 'week' | 'month' | 'year' | 'all'
final data = result.data;
// { user: {...}, global: {...}, dailySeries: [...], monthlySeries: [...], byCategory: [...] }
```

## Installation et déploiement

```bash
cd functions
npm install
npm run deploy
```

## Tester en local

```bash
npm run serve
```
Puis, dans l'émulateur Firestore, crée manuellement une offre et une
réservation, passe `status` à `"completed"`, et vérifie que les
documents `impactGlobal/summary` etc. se mettent à jour.