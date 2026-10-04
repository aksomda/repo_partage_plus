import { Router } from 'express';

import { isDatabaseUnavailable, query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { HttpError } from '../http/errors.js';
import { firestoreMirror } from '../services/firestore_mirror.js';

export const impactRouter = Router();

/** Poids sauvé par une réservation : part du poids de l'offre réservée. */
const SAVED_KG = 'COALESCE(o.weight_kg, 0) * r.quantity / o.initial_quantity';

/** Mesures communes : retraits, produits, kg, CO2 et repas. */
const MEASURES = `
  COUNT(*) AS pickups,
  COALESCE(SUM(r.quantity), 0) AS items,
  COALESCE(SUM(${SAVED_KG}), 0) AS food_kg,
  COALESCE(SUM(${SAVED_KG} * COALESCE(f.co2_kg_per_kg, 0)), 0) AS co2_kg,
  COALESCE(SUM(${SAVED_KG} * COALESCE(f.meals_per_kg, 0)), 0) AS meals`;

const PICKED_UP = `
  FROM reservations r
  JOIN offers o ON o.id = r.offer_id
  LEFT JOIN impact_factors f ON f.category_id = o.category_id
  WHERE r.status = 'picked_up'`;

export const IMPACT_SELECT = `SELECT ${MEASURES} ${PICKED_UP}`;

/** Retraits qui concernent l'utilisateur, comme donateur ou bénéficiaire. */
const MINE = 'AND (r.beneficiary_id = ? OR o.donor_id = ?)';

/** Nombre de mois du graphique d'évolution (mois en cours compris). */
export const MONTHS = 12;

const round1 = (value) => Number(Number(value).toFixed(1));

export function formatImpact(row) {
  return {
    pickups: Number(row.pickups),
    items: Number(row.items ?? 0),
    food_kg: round1(row.food_kg),
    co2_kg: round1(row.co2_kg),
    meals: Math.round(Number(row.meals)),
  };
}

/** Premier jour (UTC) du mois situé [back] mois avant celui de [date]. */
function monthStart(date, back = 0) {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() - back, 1));
}

const monthKey = (date) => date.toISOString().slice(0, 7);

/**
 * Les [MONTHS] derniers mois, du plus ancien au plus récent, y compris
 * ceux sans retrait (à zéro) : la courbe ne relie pas des mois éloignés.
 */
export function fillMonths(rows, now = new Date()) {
  const byMonth = new Map(rows.map((row) => [row.month, row]));
  return Array.from({ length: MONTHS }, (_, i) => {
    const month = monthKey(monthStart(now, MONTHS - 1 - i));
    const row = byMonth.get(month);
    return { month, ...formatImpact(row ?? { pickups: 0, food_kg: 0, co2_kg: 0, meals: 0 }) };
  });
}

async function monthly(where, params, now) {
  const rows = await query(
    `SELECT DATE_FORMAT(r.picked_up_at, '%Y-%m') AS month, ${MEASURES} ${PICKED_UP}
       AND r.picked_up_at >= ? ${where}
     GROUP BY month`,
    [monthStart(now, MONTHS - 1), ...params],
  );
  return fillMonths(rows, now);
}

async function byCategory(where, params) {
  const rows = await query(
    `SELECT c.id AS category_id, c.name AS category_name, ${MEASURES}
     FROM reservations r
     JOIN offers o ON o.id = r.offer_id
     JOIN categories c ON c.id = o.category_id
     LEFT JOIN impact_factors f ON f.category_id = o.category_id
     WHERE r.status = 'picked_up' ${where}
     GROUP BY c.id, c.name
     ORDER BY food_kg DESC`,
    params,
  );
  return rows.map((row) => ({
    category_id: row.category_id,
    category_name: row.category_name,
    ...formatImpact(row),
  }));
}

/**
 * Indicateurs sociaux : ce que l'utilisateur a apporté comme donateur, et
 * reçu comme bénéficiaire. Un invité (sans compte) est compté par téléphone.
 */
async function social(userId) {
  const [[given], [received], [shared]] = await Promise.all([
    query(
      `SELECT COUNT(DISTINCT COALESCE(CONCAT('u', r.beneficiary_id), CONCAT('g', r.guest_phone)))
                AS people_helped,
              COUNT(DISTINCT CASE WHEN b.role = 'association' THEN b.id END) AS associations_supported,
              COUNT(*) AS pickups_given
       FROM reservations r
       JOIN offers o ON o.id = r.offer_id
       LEFT JOIN users b ON b.id = r.beneficiary_id
       WHERE r.status = 'picked_up' AND o.donor_id = ?`,
      [userId],
    ),
    query(
      `SELECT COUNT(*) AS pickups_received,
              COUNT(DISTINCT COALESCE(CONCAT('u', o.donor_id), CONCAT('g', o.guest_phone)))
                AS donors_met,
              COALESCE(SUM(r.amount = 0), 0) AS free_received
       FROM reservations r
       JOIN offers o ON o.id = r.offer_id
       WHERE r.status = 'picked_up' AND r.beneficiary_id = ?`,
      [userId],
    ),
    query(
      `SELECT COUNT(*) AS offers_shared FROM offers
       WHERE donor_id = ? AND status IN ('published', 'reserved', 'completed', 'expired')`,
      [userId],
    ),
  ]);
  const count = (value) => Number(value ?? 0);
  return {
    offers_shared: count(shared.offers_shared),
    pickups_given: count(given.pickups_given),
    people_helped: count(given.people_helped),
    associations_supported: count(given.associations_supported),
    pickups_received: count(received.pickups_received),
    donors_met: count(received.donors_met),
    free_received: count(received.free_received),
  };
}

/**
 * Tableau de bord d'impact complet de l'utilisateur, calculé depuis MySQL.
 * Une copie est gardée dans Firestore (impact_dashboards) : elle sert si
 * MySQL devient indisponible.
 */
export async function buildDashboard(userId, now = new Date()) {
  const params = [userId, userId];
  const [[totals], months, categories, indicators] = await Promise.all([
    query(`${IMPACT_SELECT} ${MINE}`, params),
    monthly(MINE, params, now),
    byCategory(MINE, params),
    social(userId),
  ]);
  const dashboard = {
    as_of: now.toISOString(),
    source: 'mysql',
    impact: formatImpact(totals),
    impact_monthly: months,
    impact_by_category: categories,
    impact_social: indicators,
  };
  firestoreMirror.saveDashboard(userId, dashboard);
  return dashboard;
}

// Tableau de bord complet de l'utilisateur connecté. MySQL indisponible :
// dernière copie enregistrée dans Firestore (source: 'firestore').
impactRouter.get('/me/dashboard', authenticate, async (req, res) => {
  try {
    res.json(await buildDashboard(req.user.id));
  } catch (error) {
    if (!isDatabaseUnavailable(error)) throw error;
    const copy = await firestoreMirror.readDashboard(req.user.id).catch(() => null);
    if (!copy) {
      throw new HttpError(503, 'Statistiques momentanément indisponibles : réessayez plus tard');
    }
    res.json({ ...copy, source: 'firestore' });
  }
});

// Impact de l'utilisateur connecté (en tant que donateur ou bénéficiaire).
impactRouter.get('/me', authenticate, async (req, res) => {
  const [row] = await query(`${IMPACT_SELECT} ${MINE}`, [req.user.id, req.user.id]);
  res.json(formatImpact(row));
});

// Répartition par catégorie pour l'utilisateur connecté.
impactRouter.get('/me/by-category', authenticate, async (req, res) => {
  res.json(await byCategory(MINE, [req.user.id, req.user.id]));
});

// Évolution sur les 12 derniers mois pour l'utilisateur connecté.
impactRouter.get('/me/monthly', authenticate, async (req, res) => {
  res.json(await monthly(MINE, [req.user.id, req.user.id], new Date()));
});

/**
 * Impact de toute la plateforme (écran « Impact » de l'administrateur) :
 * totaux, évolution sur 12 mois et répartition par catégorie.
 */
export async function buildGlobalImpact(now = new Date()) {
  const [[totals], [users], months, categories] = await Promise.all([
    query(IMPACT_SELECT),
    query("SELECT COUNT(*) AS count FROM users WHERE status = 'active' AND role <> 'admin'"),
    monthly('', [], now),
    byCategory('', []),
  ]);
  return {
    as_of: now.toISOString(),
    impact: { ...formatImpact(totals), users: Number(users.count) },
    monthly: months,
    by_category: categories,
  };
}

// Impact global de la plateforme (public, pour l'écran d'accueil et la démo).
impactRouter.get('/global', async (req, res) => {
  const [row] = await query(IMPACT_SELECT);
  const [users] = await query(
    "SELECT COUNT(*) AS count FROM users WHERE status = 'active' AND role <> 'admin'",
  );
  res.json({ ...formatImpact(row), users: Number(users.count) });
});

// Répartition par catégorie, plateforme entière (tableau de bord web).
impactRouter.get('/global/by-category', async (req, res) => {
  res.json(await byCategory('', []));
});

// Évolution sur les 12 derniers mois, plateforme entière.
impactRouter.get('/global/monthly', async (req, res) => {
  res.json(await monthly('', [], new Date()));
});
