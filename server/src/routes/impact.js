import { Router } from 'express';

import { query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';

export const impactRouter = Router();

// Part du poids de l'offre correspondant à la réservation, multipliée par les facteurs.
export const IMPACT_SELECT = `
  SELECT COUNT(*) AS pickups,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity), 0) AS food_kg,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity * COALESCE(f.co2_kg_per_kg, 0)), 0) AS co2_kg,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity * COALESCE(f.meals_per_kg, 0)), 0) AS meals
  FROM reservations r
  JOIN offers o ON o.id = r.offer_id
  LEFT JOIN impact_factors f ON f.category_id = o.category_id
  WHERE r.status = 'picked_up'`;

export function formatImpact(row) {
  const round = (value, digits = 1) => Number(Number(value).toFixed(digits));
  return {
    pickups: Number(row.pickups),
    food_kg: round(row.food_kg),
    co2_kg: round(row.co2_kg),
    meals: Math.round(Number(row.meals)),
  };
}

// Impact de l'utilisateur connecté (en tant que donateur ou bénéficiaire).
impactRouter.get('/me', authenticate, async (req, res) => {
  const [row] = await query(
    `${IMPACT_SELECT} AND (r.beneficiary_id = ? OR o.donor_id = ?)`,
    [req.user.id, req.user.id],
  );
  res.json(formatImpact(row));
});

// Impact global de la plateforme (public, pour l'écran d'accueil et la démo).
impactRouter.get('/global', async (req, res) => {
  const [row] = await query(IMPACT_SELECT);
  const [users] = await query(
    "SELECT COUNT(*) AS count FROM users WHERE status = 'active' AND role <> 'admin'",
  );
  res.json({ ...formatImpact(row), users: Number(users.count) });

});
// Répartition par catégorie (camembert "Répartition des produits sauvés").
const IMPACT_BY_CATEGORY_SELECT = `
  SELECT c.id AS category_id, c.name AS category_name,
         COUNT(*) AS pickups,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity), 0) AS food_kg,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity * COALESCE(f.co2_kg_per_kg, 0)), 0) AS co2_kg,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity * COALESCE(f.meals_per_kg, 0)), 0) AS meals
  FROM reservations r
  JOIN offers o ON o.id = r.offer_id
  JOIN categories c ON c.id = o.category_id
  LEFT JOIN impact_factors f ON f.category_id = o.category_id
  WHERE r.status = 'picked_up'`;

// Évolution mois par mois (graphique "Évolution de l'impact").
const IMPACT_MONTHLY_SELECT = `
  SELECT DATE_FORMAT(r.picked_up_at, '%Y-%m') AS month,
         COUNT(*) AS pickups,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity), 0) AS food_kg,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity * COALESCE(f.co2_kg_per_kg, 0)), 0) AS co2_kg,
         COALESCE(SUM(o.weight_kg * r.quantity / o.initial_quantity * COALESCE(f.meals_per_kg, 0)), 0) AS meals
  FROM reservations r
  JOIN offers o ON o.id = r.offer_id
  LEFT JOIN impact_factors f ON f.category_id = o.category_id
  WHERE r.status = 'picked_up'`;

function formatCategoryRow(row) {
  const round = (value, digits = 1) => Number(Number(value).toFixed(digits));
  return {
    category_id: row.category_id,
    category_name: row.category_name,
    pickups: Number(row.pickups),
    food_kg: round(row.food_kg),
    co2_kg: round(row.co2_kg),
    meals: Math.round(Number(row.meals)),
  };
}

function formatMonthlyRow(row) {
  const round = (value, digits = 1) => Number(Number(value).toFixed(digits));
  return {
    month: row.month,
    pickups: Number(row.pickups),
    food_kg: round(row.food_kg),
    co2_kg: round(row.co2_kg),
    meals: Math.round(Number(row.meals)),
  };
}

// Répartition par catégorie pour l'utilisateur connecté.
impactRouter.get('/me/by-category', authenticate, async (req, res) => {
  const rows = await query(
    `${IMPACT_BY_CATEGORY_SELECT} AND (r.beneficiary_id = ? OR o.donor_id = ?)
     GROUP BY c.id, c.name ORDER BY food_kg DESC`,
    [req.user.id, req.user.id],
  );
  res.json(rows.map(formatCategoryRow));
});

// Évolution mensuelle pour l'utilisateur connecté (12 derniers mois).
impactRouter.get('/me/monthly', authenticate, async (req, res) => {
  const rows = await query(
    `${IMPACT_MONTHLY_SELECT} AND (r.beneficiary_id = ? OR o.donor_id = ?)
     GROUP BY month ORDER BY month ASC LIMIT 12`,
    [req.user.id, req.user.id],
  );
  res.json(rows.map(formatMonthlyRow));
});

// Répartition par catégorie, plateforme entière (tableau de bord web).
impactRouter.get('/global/by-category', async (req, res) => {
  const rows = await query(
    `${IMPACT_BY_CATEGORY_SELECT} GROUP BY c.id, c.name ORDER BY food_kg DESC`,
  );
  res.json(rows.map(formatCategoryRow));
});

// Évolution mensuelle, plateforme entière.
impactRouter.get('/global/monthly', async (req, res) => {
  const rows = await query(`${IMPACT_MONTHLY_SELECT} GROUP BY month ORDER BY month ASC LIMIT 12`);
  res.json(rows.map(formatMonthlyRow));
});
