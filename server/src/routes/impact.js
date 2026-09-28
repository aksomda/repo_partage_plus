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
