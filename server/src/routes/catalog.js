import { Router } from 'express';

import { query } from '../db/pool.js';

/** Référentiels publics : catégories et facteurs d'impact. */
export const catalogRouter = Router();

catalogRouter.get('/categories', async (req, res) => {
  const rows = await query(
    `SELECT c.*, f.co2_kg_per_kg, f.meals_per_kg
     FROM categories c
     LEFT JOIN impact_factors f ON f.category_id = c.id
     ORDER BY c.name`,
  );
  res.json(rows);
});

catalogRouter.get('/factors', async (req, res) => {
  const rows = await query(
    `SELECT f.*, c.name AS category_name
     FROM impact_factors f
     JOIN categories c ON c.id = f.category_id
     ORDER BY c.name`,
  );
  res.json(rows);
});
