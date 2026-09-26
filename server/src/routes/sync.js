import { Router } from 'express';

import { query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { OFFER_AVAILABLE, OFFER_SELECT } from '../services/offers.js';
import { loadProfile } from './auth.js';
import { formatImpact, IMPACT_SELECT } from './impact.js';
import { forViewer, RESERVATION_SELECT } from './reservations.js';

export const syncRouter = Router();

/** Nombre maximal d'offres disponibles copiées sur l'appareil. */
const MAX_OFFERS = 500;

/**
 * Instantané de toutes les données utiles à l'utilisateur, stocké tel quel
 * par l'application pour fonctionner hors ligne (une seule requête).
 */
syncRouter.get('/', authenticate, async (req, res) => {
  const userId = req.user.id;
  const isDonor = req.user.role === 'donor';
  const isAdmin = req.user.role === 'admin';

  const [
    profile,
    categories,
    offers,
    reservations,
    received,
    myOffers,
    notifications,
    [impact],
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
      ? query(`${OFFER_SELECT} WHERE o.donor_id = ? ORDER BY o.created_at DESC`, [userId])
      : [],
    query('SELECT * FROM notifications WHERE user_id = ? ORDER BY id DESC LIMIT 100', [
      userId,
    ]),
    query(`${IMPACT_SELECT} AND (r.beneficiary_id = ? OR o.donor_id = ?)`, [userId, userId]),
  ]);

  const admin = isAdmin
    ? {
        pending_offers: await query(
          `${OFFER_SELECT} WHERE o.status = 'pending' ORDER BY o.created_at ASC`,
        ),
        pending_associations: await query(
          `SELECT a.*, u.name AS user_name, u.email, u.phone
           FROM associations a JOIN users u ON u.id = a.user_id
           WHERE a.status = 'pending' ORDER BY a.created_at ASC`,
        ),
        factors: await query(
          `SELECT f.*, c.name AS category_name FROM impact_factors f
           JOIN categories c ON c.id = f.category_id ORDER BY c.name`,
        ),
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
    impact: formatImpact(impact),
    admin,
  });
});
