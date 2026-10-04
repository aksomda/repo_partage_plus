import { Router } from 'express';

import { query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { OFFER_AVAILABLE, OFFER_SELECT, OWN_OFFER_SELECT } from '../services/offers.js';
import { loadSettings } from '../services/settings.js';
import { loadStats, USER_SELECT } from './admin.js';
import { loadProfile } from './auth.js';
import { MESSAGE_SELECT } from './messages.js';
import { buildDashboard, buildGlobalImpact } from './impact.js';
import { forViewer, RESERVATION_SELECT } from './reservations.js';

export const syncRouter = Router();

/** Nombre maximal d'offres disponibles copiées sur l'appareil. */
const MAX_OFFERS = 500;

/** Nombre maximal de comptes copiés sur l'appareil d'un administrateur. */
const MAX_USERS = 2000;

/** Messages du mini chat copiés sur l'appareil (×4 pour un administrateur). */
const MAX_MESSAGES = 500;

/** Nombre maximal de réservations (toute la plateforme) copiées pour l'admin. */
const MAX_ADMIN_RESERVATIONS = 1000;

const CATEGORIES_SQL = `SELECT c.*, f.co2_kg_per_kg, f.meals_per_kg
  FROM categories c LEFT JOIN impact_factors f ON f.category_id = c.id
  ORDER BY c.name`;

/**
 * Instantané public pour les visiteurs sans compte : catégories et offres
 * disponibles, copiées sur l'appareil pour chercher et filtrer hors ligne.
 */
syncRouter.get('/public', async (req, res) => {
  const [categories, offers] = await Promise.all([
    query(CATEGORIES_SQL),
    query(`${OFFER_SELECT} WHERE ${OFFER_AVAILABLE} ORDER BY o.expiry_date ASC LIMIT ?`, [
      MAX_OFFERS,
    ]),
  ]);
  res.json({ server_time: new Date().toISOString(), categories, offers });
});

/**
 * Instantané de toutes les données utiles à l'utilisateur, stocké tel quel
 * par l'application pour fonctionner hors ligne (une seule requête).
 */
syncRouter.get('/', authenticate, async (req, res) => {
  const userId = req.user.id;
  // Tout le monde peut publier : publications et réservations reçues pour tous.
  const isDonor = req.user.role !== 'admin';
  const isAdmin = req.user.role === 'admin';

  const [
    profile,
    categories,
    offers,
    reservations,
    received,
    myOffers,
    notifications,
    messages,
    dashboard,
  ] = await Promise.all([
    loadProfile(userId),
    query(
      `SELECT c.*, f.co2_kg_per_kg, f.meals_per_kg
       FROM categories c LEFT JOIN impact_factors f ON f.category_id = c.id
       ORDER BY c.name`,
    ),
    query(
      `${OFFER_SELECT} WHERE ${OFFER_AVAILABLE} ORDER BY o.expiry_date ASC LIMIT ?`,
      [MAX_OFFERS],
    ),
    query(`${RESERVATION_SELECT} WHERE r.beneficiary_id = ? ORDER BY r.created_at DESC`, [
      userId,
    ]),
    isDonor
      ? query(`${RESERVATION_SELECT} WHERE o.donor_id = ? ORDER BY r.created_at DESC`, [userId])
      : [],
    isDonor
      ? query(`${OWN_OFFER_SELECT} WHERE o.donor_id = ? ORDER BY o.created_at DESC`, [userId])
      : [],
    query('SELECT * FROM notifications WHERE user_id = ? ORDER BY id DESC LIMIT 100', [
      userId,
    ]),
    // Mini chat : sa conversation ; pour un administrateur, toutes.
    isAdmin
      ? query(`${MESSAGE_SELECT} ORDER BY m.id DESC LIMIT ?`, [MAX_MESSAGES * 4])
      : query(`${MESSAGE_SELECT} WHERE m.user_id = ? ORDER BY m.id DESC LIMIT ?`, [
          userId,
          MAX_MESSAGES,
        ]),
    buildDashboard(userId),
  ]);

  const admin = isAdmin
    ? {
        // Offres visibles, que l'administrateur peut retirer en cas d'abus.
        moderation_offers: await query(
          `${OFFER_SELECT} WHERE o.status IN ('published', 'reserved') ORDER BY o.created_at DESC LIMIT ?`,
          [MAX_OFFERS],
        ),
        pending_associations: await query(
          `SELECT a.*, u.name AS user_name, u.email, u.phone
           FROM associations a JOIN users u ON u.id = a.user_id
           WHERE a.status = 'pending' ORDER BY a.created_at ASC`,
        ),
        actors: await query(
          `SELECT a.*, (SELECT COUNT(*) FROM users u WHERE u.actor_id = a.id) AS users_count
           FROM actors a ORDER BY a.sort_order, a.label`,
        ),
        factors: await query(
          `SELECT f.*, c.name AS category_name FROM impact_factors f
           JOIN categories c ON c.id = f.category_id ORDER BY c.name`,
        ),
        settings: await loadSettings(),
        // Comptes, gardés sur l'appareil : gestion des utilisateurs hors ligne.
        users: await query(`${USER_SELECT} ORDER BY u.created_at DESC LIMIT ?`, [MAX_USERS]),
        // Réservations de toute la plateforme (sans code de retrait), impact
        // global et compteurs : écrans Réservations, Impact et Administration.
        reservations: (
          await query(`${RESERVATION_SELECT} ORDER BY r.created_at DESC LIMIT ?`, [
            MAX_ADMIN_RESERVATIONS,
          ])
        ).map((row) => forViewer(row, req.user)),
        impact_global: await buildGlobalImpact(),
        stats: await loadStats(),
      }
    : null;

  res.json({
    server_time: new Date().toISOString(),
    profile,
    categories,
    offers,
    reservations,
    received: received.map((row) => forViewer(row, req.user)),
    my_offers: myOffers,
    notifications,
    messages,
    // Compteurs, évolution sur 12 mois, catégories et indicateurs sociaux :
    // gardés sur l'appareil pour l'écran « Mon impact » hors ligne.
    impact: dashboard.impact,
    impact_monthly: dashboard.impact_monthly,
    impact_by_category: dashboard.impact_by_category,
    impact_social: dashboard.impact_social,
    impact_as_of: dashboard.as_of,
    impact_source: dashboard.source,
    admin,
  });
});
