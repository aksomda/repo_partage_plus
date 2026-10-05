import { Router } from 'express';
import { z } from 'zod';

import { pool, query, transaction } from '../db/pool.js';
import { authenticate, optionalAuth } from '../http/auth.js';
import { HttpError, notFound } from '../http/errors.js';
import {
  id,
  idParam,
  isoDate,
  latitude,
  longitude,
  pagination,
} from '../http/validation.js';
import {
  assertGuestQuota,
  guestSchema,
  guestTokenOf,
  hasGuestAccess,
  issueGuestToken,
  recordGuestSubmission,
} from '../services/guests.js';
import { donorInsights } from '../services/insights.js';
import { notify } from '../services/notifications.js';
import { photoSchema, savePhoto } from '../services/photos.js';
import { notifySearchMatches } from '../services/search_alerts.js';
import {
  assertPickupDates,
  DISTANCE_KM,
  expiryEnd,
  DONOR_NAME,
  PUBLISHER_TYPE,
  OFFER_AVAILABLE,
  OFFER_SELECT,
  OWN_OFFER_SELECT,
  MAX_SLOTS,
  normalizeSlots,
  saveContactEmail,
  saveSlots,
  SLOTS_JSON,
} from '../services/offers.js';

export const offersRouter = Router();

const offerSchema = z
  .object({
    category_id: id,
    title: z.string().trim().min(3).max(150),
    description: z.string().trim().max(2000).optional(),
    quantity: z.coerce.number().int().min(1).max(10000),
    unit: z.string().trim().min(1).max(30).default('portion'),
    // Facultatif : vide ou absent = inconnu.
    weight_kg: z.preprocess(
      (value) => (value === '' ? null : value),
      z.coerce.number().positive().max(10000).nullable().optional(),
    ),
    // Prix par unité en F CFA ; 0 = don gratuit.
    price: z.coerce.number().min(0).max(10_000_000).default(0),
    payment_info: z.string().trim().max(255).nullable().optional(),
    contact_email: z.preprocess(
      (value) => (value === '' ? null : value),
      z.string().trim().toLowerCase().email('Adresse e-mail invalide').max(255).nullable().optional(),
    ),
    country_code: z.string().trim().regex(/^[A-Za-z]{2}$/).toUpperCase().nullable().optional(),
    country_name: z.string().trim().max(80).nullable().optional(),
    expiry_date: isoDate,
    pickup_start: z.coerce.date().optional(),
    pickup_end: z.coerce.date().optional(),
    address: z.string().trim().min(3).max(255),
    latitude,
    longitude,
    photo: photoSchema,
    // Plusieurs créneaux de retrait ; absent : un seul (pickup_start → pickup_end).
    slots: z
      .array(z.object({ start: z.coerce.date(), end: z.coerce.date() }))
      .max(MAX_SLOTS, `${MAX_SLOTS} créneaux maximum`)
      .optional(),
  })
  .refine((data) => (data.slots ?? []).every((slot) => slot.end > slot.start), {
    message: 'Chaque créneau doit finir après son début',
    path: ['slots'],
  })
  .refine((data) => data.slots?.length || data.pickup_end > data.pickup_start, {
    message: 'La fin du retrait doit être après le début',
    path: ['pickup_end'],
  })
  .refine((data) => data.price === 0 || data.payment_info, {
    message: 'Indiquez comment payer (ex. : Orange Money 70 00 00 00)',
    path: ['payment_info'],
  });

/** Sans compte, l'identité du publieur est obligatoire. */
const guestOfferSchema = z.object({ guest: guestSchema });

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

/** Propriétaire : le compte qui l'a publiée, ou l'invité muni de son jeton. */
async function canManage(offer, req) {
  if (req.user) return offer.donor_id === req.user.id;
  return (
    offer.donor_id === null &&
    hasGuestAccess(pool, 'offer', offer.id, guestTokenOf(req))
  );
}

async function loadOwnOffer(offerId, req) {
  const [offer] = await query('SELECT * FROM offers WHERE id = ?', [offerId]);
  if (!offer) throw notFound('Offre');
  if (!(await canManage(offer, req))) {
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
       SELECT o.*, c.name AS category_name, c.icon AS category_icon, ${DONOR_NAME} AS donor_name, ${PUBLISHER_TYPE} AS publisher_type,
              o.donor_id IS NULL AS is_guest, o.guest_phone AS contact_phone,
              ${SLOTS_JSON} AS slots, ${DISTANCE_KM} AS distance_km
       FROM offers o
       JOIN categories c ON c.id = o.category_id
       LEFT JOIN users u ON u.id = o.donor_id
       LEFT JOIN actors pa ON pa.id = u.actor_id
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

// Offres publiées par l'utilisateur connecté, tous statuts confondus.
offersRouter.get('/mine', authenticate, async (req, res) => {
  const offers = await query(
    `${OFFER_SELECT} WHERE o.donor_id = ? ORDER BY o.created_at DESC`,
    [req.user.id],
  );
  res.json(offers);
});

// Risque de gaspillage et suggestions pour chaque offre en cours du donateur.
offersRouter.get('/mine/insights', authenticate, async (req, res) => {
  res.json(await donorInsights(req.user.id));
});

// Photo de l'offre (public, comme l'offre ; mise en cache, l'URL change
// avec la photo). Pas servie pour une offre refusée par la modération.
offersRouter.get('/:id/photo', async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const [photo] = await query(
    `SELECT p.mime, p.data FROM offer_photos p
     JOIN offers o ON o.id = p.offer_id
     WHERE p.offer_id = ? AND o.status <> 'rejected'`,
    [offerId],
  );
  if (!photo) throw notFound('Photo');
  res
    .type(photo.mime)
    .set('Cache-Control', 'public, max-age=604800, immutable')
    .send(photo.data);
});

offersRouter.get('/:id', optionalAuth, async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const [offer] = await query(`${OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  if (!offer) throw notFound('Offre');

  const canSeeAll =
    req.user?.role === 'admin' || (await canManage(offer, req));
  if (offer.status !== 'published' && offer.status !== 'reserved' && !canSeeAll) {
    throw notFound('Offre');
  }
  res.json(offer);
});

// Création, avec ou sans compte : visible tout de suite (l'administrateur retire les abus).
offersRouter.post('/', optionalAuth, async (req, res) => {
  if (req.user?.role === 'admin') {
    throw new HttpError(403, 'Un administrateur ne publie pas d’offres');
  }
  const data = offerSchema.parse(req.body);
  const { slots, pickupStart, pickupEnd } = normalizeSlots(data);
  assertPickupDates(slots, data.expiry_date);
  const guest = req.user ? null : guestOfferSchema.parse(req.body).guest;
  if (guest) await assertGuestQuota('offer', guest.phone, req.ip);

  const { offerId, guestToken } = await transaction(async (conn) => {
    const [result] = await conn.query('INSERT INTO offers SET ?', [
      {
        donor_id: req.user?.id ?? null,
        guest_first_name: guest?.first_name ?? null,
        guest_last_name: guest?.last_name ?? null,
        guest_phone: guest?.phone ?? null,
        category_id: data.category_id,
        title: data.title,
        description: data.description ?? null,
        initial_quantity: data.quantity,
        quantity_available: data.quantity,
        unit: data.unit,
        weight_kg: data.weight_kg ?? null,
        price: data.price,
        payment_info: data.price > 0 ? data.payment_info : null,
        country_code: data.country_code ?? null,
        country_name: data.country_name ?? null,
        // Visible tout de suite : l'administrateur retire après coup les abus.
        status: 'published',
        expiry_date: data.expiry_date,
        pickup_start: pickupStart,
        pickup_end: pickupEnd,
        address: data.address,
        latitude: data.latitude,
        longitude: data.longitude,
      },
    ]);
    await savePhoto(conn, result.insertId, data.photo);
    await saveSlots(conn, result.insertId, slots);
    await saveContactEmail(conn, result.insertId, data.contact_email);
    if (guest) await recordGuestSubmission(conn, 'offer', guest.phone, req.ip);
    return {
      offerId: result.insertId,
      guestToken: guest ? await issueGuestToken(conn, 'offer', result.insertId) : null,
    };
  });

  const [offer] = await query(`${OWN_OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  // Alertes des recherches enregistrées : sans faire attendre le publieur.
  notifySearchMatches(offer).catch((error) =>
    console.error('Alertes de recherche non envoyées :', error.message),
  );
  // Le jeton n'est remis qu'une fois : l'application le garde sur l'appareil.
  res.status(201).json(guestToken ? { ...offer, guest_token: guestToken } : offer);
});

// Modification par le publieur (compte, ou invité muni de son jeton) :
// seulement sans réservation ; l'offre reste publiée (l'administrateur
// retire après coup les abus, comme à la création).
offersRouter.put('/:id', optionalAuth, async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const data = offerSchema.parse(req.body);
  const { slots, pickupStart, pickupEnd } = normalizeSlots(data);
  assertPickupDates(slots, data.expiry_date);
  const offer = await loadOwnOffer(offerId, req);

  // Offre retirée par l'administrateur : plus modifiable (pas de republication).
  if (!['pending', 'published'].includes(offer.status)) {
    throw new HttpError(409, `Offre non modifiable (statut : ${offer.status})`);
  }
  if (offer.quantity_available !== offer.initial_quantity) {
    throw new HttpError(409, 'Offre déjà réservée, modification impossible');
  }

  await transaction(async (conn) => {
    await conn.query(
      `UPDATE offers SET category_id = ?, title = ?, description = ?, initial_quantity = ?,
         quantity_available = ?, unit = ?, weight_kg = ?, price = ?, payment_info = ?,
         country_code = ?, country_name = ?,
         expiry_date = ?, pickup_start = ?,
         pickup_end = ?, address = ?, latitude = ?, longitude = ?,
         status = 'published', expiry_notified_at = NULL
       WHERE id = ?`,
      [
        data.category_id,
        data.title,
        data.description ?? null,
        data.quantity,
        data.quantity,
        data.unit,
        data.weight_kg ?? null,
        data.price,
        data.price > 0 ? data.payment_info : null,
        data.country_code ?? offer.country_code,
        data.country_name ?? offer.country_name,
        data.expiry_date,
        pickupStart,
        pickupEnd,
        data.address,
        data.latitude,
        data.longitude,
        offerId,
      ],
    );
    await savePhoto(conn, offerId, data.photo);
    await saveSlots(conn, offerId, slots);
    await saveContactEmail(conn, offerId, data.contact_email);
  });

  const [updated] = await query(`${OWN_OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  res.json(updated);
});

const slotsUpdateSchema = z
  .object({
    slots: z
      .array(
        z.object({
          // Absent : nouveau créneau ; sinon créneau existant modifié.
          id: id.optional(),
          start: z.coerce.date(),
          end: z.coerce.date(),
        }),
      )
      .min(1, 'Au moins un créneau')
      .max(MAX_SLOTS, `${MAX_SLOTS} créneaux maximum`),
  })
  .refine((data) => data.slots.every((slot) => slot.end > slot.start), {
    message: 'Chaque créneau doit finir après son début',
    path: ['slots'],
  });

const slotLabel = (start, end) => {
  const format = (date, options) =>
    new Date(date).toLocaleString('fr-FR', { timeZone: 'UTC', ...options });
  const day = format(start, { day: '2-digit', month: '2-digit' });
  const hour = (date) => format(date, { hour: '2-digit', minute: '2-digit' });
  return `le ${day} de ${hour(start)} à ${hour(end)} (UTC)`;
};

// Créneaux d'une offre publiée, avec ou sans réservations, par son
// publieur (compte, ou invité muni de son jeton). Un créneau réservé peut
// être déplacé (les bénéficiaires sont prévenus), pas supprimé.
offersRouter.patch('/:id/slots', optionalAuth, async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const { slots } = slotsUpdateSchema.parse(req.body);
  const offer = await loadOwnOffer(offerId, req);
  if (!['published', 'reserved'].includes(offer.status)) {
    throw new HttpError(409, `Créneaux non modifiables (statut : ${offer.status})`);
  }

  await transaction(async (conn) => {
    const [existing] = await conn.query(
      'SELECT id, start_at, end_at FROM offer_slots WHERE offer_id = ? FOR UPDATE',
      [offerId],
    );
    const byId = new Map(existing.map((slot) => [slot.id, slot]));
    const unknown = slots.find((slot) => slot.id && !byId.has(slot.id));
    if (unknown) throw new HttpError(400, 'Créneau inconnu pour cette offre', { field: 'slots' });

    const now = new Date();
    const changed = slots.filter((slot) => {
      const before = slot.id ? byId.get(slot.id) : null;
      return (
        !before ||
        before.start_at.getTime() !== slot.start.getTime() ||
        before.end_at.getTime() !== slot.end.getTime()
      );
    });
    if (changed.some((slot) => slot.end <= now)) {
      throw new HttpError(400, 'Un créneau modifié ou ajouté doit finir dans le futur', {
        field: 'slots',
      });
    }
    if (changed.some((slot) => slot.end > expiryEnd(offer.expiry_date))) {
      throw new HttpError(
        400,
        'Le retrait doit se terminer au plus tard le jour de la date limite',
        { field: 'slots', code: 'pickup_after_expiry' },
      );
    }

    const kept = new Set(slots.filter((slot) => slot.id).map((slot) => slot.id));
    const removed = existing.filter((slot) => !kept.has(slot.id)).map((slot) => slot.id);
    if (removed.length > 0) {
      const [[{ count }]] = await conn.query(
        `SELECT COUNT(*) AS count FROM reservations
         WHERE slot_id IN (?) AND status IN ('pending', 'confirmed')`,
        [removed],
      );
      if (count > 0) {
        throw new HttpError(
          409,
          'Un créneau supprimé a des réservations en cours : déplacez-le plutôt que de le supprimer',
          { code: 'slot_reserved' },
        );
      }
      await conn.query('DELETE FROM offer_slots WHERE id IN (?)', [removed]);
    }

    for (const slot of slots) {
      if (!slot.id) {
        await conn.query('INSERT INTO offer_slots (offer_id, start_at, end_at) VALUES (?, ?, ?)', [
          offerId,
          slot.start,
          slot.end,
        ]);
        continue;
      }
      if (!changed.includes(slot)) continue;
      await conn.query('UPDATE offer_slots SET start_at = ?, end_at = ? WHERE id = ?', [
        slot.start,
        slot.end,
        slot.id,
      ]);
      // Réservations sur ce créneau : nouvel horaire, rappels à renvoyer.
      const [moved] = await conn.query(
        `SELECT id, beneficiary_id FROM reservations
         WHERE slot_id = ? AND status IN ('pending', 'confirmed') FOR UPDATE`,
        [slot.id],
      );
      await conn.query(
        `UPDATE reservations SET slot_start = ?, slot_end = ?, reminder_sent_at = NULL,
           confirm_reminder_sent_at = NULL
         WHERE slot_id = ? AND status IN ('pending', 'confirmed')`,
        [slot.start, slot.end, slot.id],
      );
      for (const reservation of moved) {
        await notify(conn, reservation.beneficiary_id, {
          type: 'slot_changed',
          title: 'Créneau de retrait modifié',
          body: `« ${offer.title} » : votre retrait est désormais ${slotLabel(slot.start, slot.end)}.`,
          data: { reservation_id: reservation.id, offer_id: offerId },
        });
      }
    }

    // Période de l'offre : premier début, dernière fin.
    const pickupStart = new Date(Math.min(...slots.map((slot) => slot.start.getTime())));
    const pickupEnd = new Date(Math.max(...slots.map((slot) => slot.end.getTime())));
    await conn.query('UPDATE offers SET pickup_start = ?, pickup_end = ? WHERE id = ?', [
      pickupStart,
      pickupEnd,
      offerId,
    ]);

    // Réservations sans créneau choisi : elles suivent la période de l'offre.
    const periodChanged =
      new Date(offer.pickup_start).getTime() !== pickupStart.getTime() ||
      new Date(offer.pickup_end).getTime() !== pickupEnd.getTime();
    if (periodChanged) {
      const [whole] = await conn.query(
        `SELECT id, beneficiary_id FROM reservations
         WHERE offer_id = ? AND slot_id IS NULL AND status IN ('pending', 'confirmed')`,
        [offerId],
      );
      await conn.query(
        `UPDATE reservations SET reminder_sent_at = NULL, confirm_reminder_sent_at = NULL
         WHERE offer_id = ? AND slot_id IS NULL AND status IN ('pending', 'confirmed')`,
        [offerId],
      );
      for (const reservation of whole) {
        await notify(conn, reservation.beneficiary_id, {
          type: 'slot_changed',
          title: 'Créneau de retrait modifié',
          body: `« ${offer.title} » : retrait désormais ${slotLabel(pickupStart, pickupEnd)}.`,
          data: { reservation_id: reservation.id, offer_id: offerId },
        });
      }
    }
  });

  const [updated] = await query(`${OWN_OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  res.json(updated);
});

// Annulation par le publieur (compte, ou invité muni de son jeton) :
// les réservations en cours sont annulées.
offersRouter.delete('/:id', optionalAuth, async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const offer = await loadOwnOffer(offerId, req);

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
