import { Router } from 'express';

import { query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { DISTANCE_KM, OFFER_AVAILABLE } from '../services/offers.js';

export const recommendationsRouter = Router();

/**
 * Offres disponibles classées par :
 * 1. catégories que l'utilisateur réserve le plus,
 * 2. distance (si sa position est connue),
 * 3. DLC la plus proche.
 */
recommendationsRouter.get('/', authenticate, async (req, res) => {
  const [me] = await query('SELECT latitude, longitude FROM users WHERE id = ?', [
    req.user.id,
  ]);
  const hasPosition = me.latitude !== null && me.longitude !== null;

  const distance = hasPosition ? DISTANCE_KM : 'NULL';
  const distanceParams = hasPosition ? [me.latitude, me.longitude, me.latitude] : [];

  const offers = await query(
    `SELECT o.*, c.name AS category_name, u.name AS donor_name,
            COALESCE(pref.score, 0) AS affinity,
            ${distance} AS distance_km
     FROM offers o
     JOIN categories c ON c.id = o.category_id
     JOIN users u ON u.id = o.donor_id
     LEFT JOIN (
       SELECT o2.category_id, COUNT(*) AS score
       FROM reservations r2
       JOIN offers o2 ON o2.id = r2.offer_id
       WHERE r2.beneficiary_id = ? AND r2.status <> 'cancelled'
       GROUP BY o2.category_id
     ) pref ON pref.category_id = o.category_id
     WHERE ${OFFER_AVAILABLE} AND o.donor_id <> ?
     ORDER BY affinity DESC, ${hasPosition ? 'distance_km ASC,' : ''} o.expiry_date ASC
     LIMIT 20`,
    [...distanceParams, req.user.id, req.user.id],
  );
  res.json(offers);
});
