import { Router } from 'express';
import { z } from 'zod';

import { query, transaction } from '../db/pool.js';
import { authenticate, optionalAuth, requireRole } from '../http/auth.js';
import { HttpError, notFound } from '../http/errors.js';
import {
  id,
  idParam,
  isoDate,
  latitude,
  longitude,
  pagination,
} from '../http/validation.js';
import { notify } from '../services/notifications.js';
import {
  DISTANCE_KM,
  OFFER_AVAILABLE,
  OFFER_SELECT,
} from '../services/offers.js';

export const offersRouter = Router();

const offerSchema = z
  .object({
    category_id: id,
    title: z.string().trim().min(3).max(150),
    description: z.string().trim().max(2000).optional(),
    quantity: z.coerce.number().int().min(1).max(10000),
    unit: z.string().trim().min(1).max(30).default('portion'),
    weight_kg: z.coerce.number().positive().max(10000),
    expiry_date: isoDate,
    pickup_start: z.coerce.date(),
    pickup_end: z.coerce.date(),
    address: z.string().trim().min(3).max(255),
    latitude,
    longitude,
  })
  .refine((data) => data.pickup_end > data.pickup_start, {
    message: 'La fin du retrait doit être après le début',
    path: ['pickup_end'],
  });

const listSchema = pagination.extend({
  category_id: id.optional(),
  q: z.string().trim().max(100).optional(),
});

const nearbySchema = z.object({
  lat: latitude,
  lng: longitude,
  radius_km: z.coerce.number().positive().max(100).default(5),
  category_id: id.optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
});

const expiringSchema = z.object({
  days: z.coerce.number().int().min(0).max(7).default(1),
});

async function loadOwnOffer(offerId, user) {
  const [offer] = await query('SELECT * FROM offers WHERE id = ?', [offerId]);
  if (!offer) throw notFound('Offre');
  if (offer.donor_id !== user.id) {
    throw new HttpError(403, 'Cette offre ne vous appartient pas');
  }
  return offer;
}

// Liste des offres disponibles (catalogue public).
offersRouter.get('/', async (req, res) => {
  const filters = listSchema.parse(req.query);
  const where = [OFFER_AVAILABLE];
  const params = [];

  if (filters.category_id) {
    where.push('o.category_id = ?');
    params.push(filters.category_id);
  }
  if (filters.q) {
    where.push('(o.title LIKE ? OR o.description LIKE ?)');
    params.push(`%${filters.q}%`, `%${filters.q}%`);
  }

  const offers = await query(
    `${OFFER_SELECT} WHERE ${where.join(' AND ')}
     ORDER BY o.expiry_date ASC, o.created_at DESC LIMIT ? OFFSET ?`,
    [...params, filters.limit, filters.offset],
  );
  res.json(offers);
});

// Offres à proximité, triées par distance.
offersRouter.get('/nearby', async (req, res) => {
  const filters = nearbySchema.parse(req.query);
  const params = [filters.lat, filters.lng, filters.lat];
  let categoryFilter = '';

  if (filters.category_id) {
    categoryFilter = 'AND o.category_id = ?';
    params.push(filters.category_id);
  }

  const offers = await query(
    `SELECT * FROM (
       SELECT o.*, c.name AS category_name, u.name AS donor_name,
              ${DISTANCE_KM} AS distance_km
       FROM offers o
       JOIN categories c ON c.id = o.category_id
       JOIN users u ON u.id = o.donor_id
       WHERE ${OFFER_AVAILABLE} ${categoryFilter}
     ) AS nearby
     WHERE distance_km <= ?
     ORDER BY distance_km ASC
     LIMIT ?`,
    [...params, filters.radius_km, filters.limit],
  );
  res.json(offers);
});

// Offres disponibles dont la DLC tombe dans les `days` prochains jours.
offersRouter.get('/expiring-soon', async (req, res) => {
  const { days } = expiringSchema.parse(req.query);
  const offers = await query(
    `${OFFER_SELECT}
     WHERE ${OFFER_AVAILABLE} AND o.expiry_date <= CURDATE() + INTERVAL ? DAY
     ORDER BY o.expiry_date ASC`,
    [days],
  );
  res.json(offers);
});

// Offres publiées par le donateur connecté, tous statuts confondus.
offersRouter.get('/mine', authenticate, requireRole('donor'), async (req, res) => {
  const offers = await query(
    `${OFFER_SELECT} WHERE o.donor_id = ? ORDER BY o.created_at DESC`,
    [req.user.id],
  );
  res.json(offers);
});

offersRouter.get('/:id', optionalAuth, async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const [offer] = await query(`${OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  if (!offer) throw notFound('Offre');

  const canSeeAll =
    req.user && (req.user.role === 'admin' || req.user.id === offer.donor_id);
  if (offer.status !== 'published' && offer.status !== 'reserved' && !canSeeAll) {
    throw notFound('Offre');
  }
  res.json(offer);
});

// Création : l'offre attend la validation d'un modérateur.
offersRouter.post('/', authenticate, requireRole('donor'), async (req, res) => {
  const data = offerSchema.parse(req.body);
  const result = await query(
    `INSERT INTO offers (donor_id, category_id, title, description, initial_quantity,
       quantity_available, unit, weight_kg, expiry_date, pickup_start, pickup_end,
       address, latitude, longitude)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      req.user.id,
      data.category_id,
      data.title,
      data.description ?? null,
      data.quantity,
      data.quantity,
      data.unit,
      data.weight_kg,
      data.expiry_date,
      data.pickup_start,
      data.pickup_end,
      data.address,
      data.latitude,
      data.longitude,
    ],
  );

  const [offer] = await query(`${OFFER_SELECT} WHERE o.id = ?`, [result.insertId]);
  res.status(201).json(offer);
});

// Modification : seulement sans réservation, et repasse en modération.
offersRouter.put('/:id', authenticate, requireRole('donor'), async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const data = offerSchema.parse(req.body);
  const offer = await loadOwnOffer(offerId, req.user);

  if (!['pending', 'published', 'rejected'].includes(offer.status)) {
    throw new HttpError(409, `Offre non modifiable (statut : ${offer.status})`);
  }
  if (offer.quantity_available !== offer.initial_quantity) {
    throw new HttpError(409, 'Offre déjà réservée, modification impossible');
  }

  await query(
    `UPDATE offers SET category_id = ?, title = ?, description = ?, initial_quantity = ?,
       quantity_available = ?, unit = ?, weight_kg = ?, expiry_date = ?, pickup_start = ?,
       pickup_end = ?, address = ?, latitude = ?, longitude = ?,
       status = 'pending', moderation_reason = NULL, expiry_notified_at = NULL
     WHERE id = ?`,
    [
      data.category_id,
      data.title,
      data.description ?? null,
      data.quantity,
      data.quantity,
      data.unit,
      data.weight_kg,
      data.expiry_date,
      data.pickup_start,
      data.pickup_end,
      data.address,
      data.latitude,
      data.longitude,
      offerId,
    ],
  );

  const [updated] = await query(`${OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  res.json(updated);
});

// Annulation par le donateur : les réservations en cours sont annulées.
offersRouter.delete('/:id', authenticate, requireRole('donor'), async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const offer = await loadOwnOffer(offerId, req.user);

  if (['completed', 'cancelled', 'expired'].includes(offer.status)) {
    throw new HttpError(409, `Offre déjà clôturée (statut : ${offer.status})`);
  }

  await transaction(async (conn) => {
    const [active] = await conn.query(
      `SELECT id, beneficiary_id FROM reservations
       WHERE offer_id = ? AND status IN ('pending', 'confirmed') FOR UPDATE`,
      [offerId],
    );

    await conn.query(
      `UPDATE reservations SET status = 'cancelled', cancelled_at = NOW()
       WHERE offer_id = ? AND status IN ('pending', 'confirmed')`,
      [offerId],
    );
    await conn.query("UPDATE offers SET status = 'cancelled' WHERE id = ?", [offerId]);

    for (const reservation of active) {
      await notify(conn, reservation.beneficiary_id, {
        type: 'reservation_cancelled',
        title: 'Réservation annulée',
        body: `L’offre « ${offer.title} » a été retirée par le donateur.`,
        data: { reservation_id: reservation.id, offer_id: offerId },
      });
    }
  });

  res.status(204).end();
});
