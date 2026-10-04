import { randomInt } from 'node:crypto';

import { Router } from 'express';
import { z } from 'zod';

import { pool, query, transaction } from '../db/pool.js';
import { authenticate, optionalAuth } from '../http/auth.js';
import { HttpError, notFound } from '../http/errors.js';
import { id, idParam } from '../http/validation.js';
import {
  guestName,
  assertGuestQuota,
  guestSchema,
  guestTokenOf,
  hasGuestAccess,
  issueGuestToken,
  recordGuestSubmission,
} from '../services/guests.js';
import { notify } from '../services/notifications.js';

export const reservationsRouter = Router();

/**
 * Publieur et bénéficiaire peuvent être des comptes ou des invités :
 * noms et téléphones sont pris dans le compte, sinon dans les champs guest_*.
 */
export const RESERVATION_SELECT = `
  SELECT r.*, o.title AS offer_title, o.unit, o.address, o.latitude, o.longitude,
         o.pickup_start, o.pickup_end, o.expiry_date, o.donor_id, o.price, o.payment_info,
         o.category_id,
         o.donor_id IS NULL AS is_guest_offer,
         COALESCE(d.name, CONCAT(o.guest_first_name, ' ', o.guest_last_name)) AS donor_name,
         COALESCE(d.phone, o.guest_phone) AS donor_phone,
         COALESCE(b.name, CONCAT(r.guest_first_name, ' ', r.guest_last_name)) AS beneficiary_name,
         COALESCE(b.phone, r.guest_phone) AS beneficiary_phone
  FROM reservations r
  JOIN offers o ON o.id = r.offer_id
  LEFT JOIN users d ON d.id = o.donor_id
  LEFT JOIN users b ON b.id = r.beneficiary_id`;

const createSchema = z.object({
  offer_id: id,
  quantity: z.coerce.number().int().min(1).default(1),
  // Référence de la transaction faite hors application (Mobile Money…).
  payment_reference: z
    .string()
    .trim()
    .regex(/^[A-Za-z0-9.\-_/ ]{4,64}$/, 'Référence de paiement invalide')
    .optional(),
});

const guestReservationSchema = z.object({ guest: guestSchema });

const pickupSchema = z.object({
  pickup_code: z.string().trim().regex(/^\d{6}$/, 'Code à 6 chiffres attendu'),
});

/** Le code de retrait n'est montré qu'au bénéficiaire, qui le donne au donateur. */
export function forViewer(reservation, user) {
  if (user && reservation.beneficiary_id === user.id) return reservation;
  const { pickup_code: _code, ...rest } = reservation;
  return rest;
}

async function loadReservation(conn, reservationId) {
  const [rows] = await conn.query(`${RESERVATION_SELECT} WHERE r.id = ? FOR UPDATE`, [
    reservationId,
  ]);
  if (!rows[0]) throw notFound('Réservation');
  return rows[0];
}

async function reload(reservationId, user) {
  const [reservation] = await query(`${RESERVATION_SELECT} WHERE r.id = ?`, [
    reservationId,
  ]);
  return forViewer(reservation, user);
}

/** Invité ayant fait la réservation, reconnu grâce à son jeton. */
async function isGuestHolder(req, reservation) {
  return (
    !req.user &&
    reservation.beneficiary_id === null &&
    hasGuestAccess(pool, 'reservation', reservation.id, guestTokenOf(req))
  );
}

/** Rend la quantité à l'offre et la republie si elle était épuisée. */
async function releaseQuantity(conn, reservation) {
  await conn.query(
    `UPDATE offers
     SET status = IF(status = 'reserved' AND pickup_end > NOW(), 'published', status),
         quantity_available = quantity_available + ?
     WHERE id = ?`,
    [reservation.quantity, reservation.offer_id],
  );
}

/** Clôture l'offre quand tout a été réservé et retiré. */
async function completeOfferIfDone(conn, offerId) {
  await conn.query(
    `UPDATE offers SET status = 'completed'
     WHERE id = ? AND quantity_available = 0
       AND NOT EXISTS (
         SELECT 1 FROM reservations
         WHERE offer_id = ? AND status IN ('pending', 'confirmed'))`,
    [offerId, offerId],
  );
}

// Réserver une offre publiée par un compte, avec ou sans compte (association :
// validée seulement). L'offre d'un invité ne se réserve pas : on l'appelle.
reservationsRouter.post('/', optionalAuth, async (req, res) => {
  const data = createSchema.parse(req.body);
  const guest = req.user ? null : guestReservationSchema.parse(req.body).guest;
  if (guest) await assertGuestQuota('reservation', guest.phone, req.ip);

  if (req.user?.role === 'admin') {
    throw new HttpError(403, 'Un administrateur ne réserve pas d’offres');
  }
  if (req.user?.role === 'association') {
    const [association] = await query('SELECT status FROM associations WHERE user_id = ?', [
      req.user.id,
    ]);
    if (association?.status !== 'approved') {
      throw new HttpError(403, 'Association pas encore validée par un administrateur');
    }
  }

  const { reservationId, guestToken } = await transaction(async (conn) => {
    const [[offer]] = await conn.query(
      `SELECT *, (expiry_date >= CURDATE() AND pickup_end > NOW()) AS still_valid
       FROM offers WHERE id = ? FOR UPDATE`,
      [data.offer_id],
    );

    if (!offer || offer.status !== 'published' || !offer.still_valid) {
      throw new HttpError(409, 'Offre indisponible');
    }
    // Publiée sans compte : personne ne pourrait confirmer ni valider le
    // retrait dans l'application, le bénéficiaire appelle le donateur.
    if (offer.donor_id === null) {
      throw new HttpError(
        409,
        `Offre publiée sans compte : appelez le donateur au ${offer.guest_phone}`,
        { code: 'guest_offer_call', phone: offer.guest_phone },
      );
    }
    if (req.user && offer.donor_id === req.user.id) {
      throw new HttpError(409, 'Impossible de réserver sa propre offre');
    }
    if (data.quantity > offer.quantity_available) {
      throw new HttpError(409, `Quantité disponible : ${offer.quantity_available}`);
    }

    const amount = Number(offer.price) * data.quantity;
    if (amount > 0 && !data.payment_reference) {
      throw new HttpError(400, 'Référence de paiement obligatoire pour une offre payante', {
        field: 'payment_reference',
      });
    }

    const [[existing]] = await conn.query(
      `SELECT id FROM reservations
       WHERE offer_id = ? AND status IN ('pending', 'confirmed')
         AND ${req.user ? 'beneficiary_id = ?' : 'beneficiary_id IS NULL AND guest_phone = ?'}`,
      [offer.id, req.user?.id ?? guest.phone],
    );
    if (existing) throw new HttpError(409, 'Vous avez déjà une réservation sur cette offre');

    const pickupCode = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const [result] = await conn.query('INSERT INTO reservations SET ?', [
      {
        offer_id: offer.id,
        beneficiary_id: req.user?.id ?? null,
        guest_first_name: guest?.first_name ?? null,
        guest_last_name: guest?.last_name ?? null,
        guest_phone: guest?.phone ?? null,
        quantity: data.quantity,
        amount,
        payment_reference: amount > 0 ? data.payment_reference : null,
        pickup_code: pickupCode,
        status: 'pending',
      },
    ]);
    if (guest) await recordGuestSubmission(conn, 'reservation', guest.phone, req.ip);

    await conn.query(
      `UPDATE offers
       SET quantity_available = quantity_available - ?,
           status = IF(quantity_available = 0, 'reserved', status)
       WHERE id = ?`,
      [data.quantity, offer.id],
    );

    const who = req.user?.name ?? guestName(guest);
    await notify(conn, offer.donor_id, {
      type: 'reservation_created',
      title: 'Nouvelle réservation',
      body:
        `${who} a réservé ${data.quantity} ${offer.unit}(s) de « ${offer.title} »` +
        (amount > 0 ? ` (paiement ${amount} F, réf. ${data.payment_reference})` : '') +
        '. Confirmez-la.',
      data: { reservation_id: result.insertId, offer_id: offer.id },
    });

    return {
      reservationId: result.insertId,
      guestToken: guest ? await issueGuestToken(conn, 'reservation', result.insertId) : null,
    };
  });

  if (guestToken) {
    const [reservation] = await query(`${RESERVATION_SELECT} WHERE r.id = ?`, [reservationId]);
    // Code de retrait et jeton remis à l'invité, qui les garde sur son appareil.
    return res.status(201).json({ ...reservation, guest_token: guestToken });
  }
  res.status(201).json(await reload(reservationId, req.user));
});

// Réservations de l'utilisateur connecté.
reservationsRouter.get('/mine', authenticate, async (req, res) => {
  const rows = await query(
    `${RESERVATION_SELECT} WHERE r.beneficiary_id = ? ORDER BY r.created_at DESC`,
    [req.user.id],
  );
  res.json(rows);
});

// Réservations reçues sur les offres de l'utilisateur connecté.
reservationsRouter.get('/received', authenticate, async (req, res) => {
  const rows = await query(
    `${RESERVATION_SELECT} WHERE o.donor_id = ? ORDER BY r.created_at DESC`,
    [req.user.id],
  );
  res.json(rows.map((row) => forViewer(row, req.user)));
});

// Réservation d'un invité, lue avec son jeton (en-tête X-Guest-Token).
reservationsRouter.get('/guest/:id', async (req, res) => {
  const { id: reservationId } = idParam.parse(req.params);
  const [reservation] = await query(`${RESERVATION_SELECT} WHERE r.id = ?`, [reservationId]);
  if (!reservation || !(await isGuestHolder(req, reservation))) {
    throw notFound('Réservation');
  }
  res.json(reservation);
});

reservationsRouter.get('/:id', authenticate, async (req, res) => {
  const { id: reservationId } = idParam.parse(req.params);
  const [reservation] = await query(`${RESERVATION_SELECT} WHERE r.id = ?`, [
    reservationId,
  ]);
  if (!reservation) throw notFound('Réservation');

  const allowed =
    req.user.role === 'admin' ||
    reservation.beneficiary_id === req.user.id ||
    reservation.donor_id === req.user.id;
  if (!allowed) throw notFound('Réservation');

  res.json(forViewer(reservation, req.user));
});

// Confirmation par le publieur (après vérification du paiement le cas échéant).
reservationsRouter.patch('/:id/confirm', authenticate, async (req, res) => {
  const { id: reservationId } = idParam.parse(req.params);

  await transaction(async (conn) => {
    const reservation = await loadReservation(conn, reservationId);
    if (reservation.donor_id !== req.user.id) throw notFound('Réservation');
    if (reservation.status !== 'pending') {
      throw new HttpError(409, `Réservation déjà ${reservation.status}`);
    }

    await conn.query(
      "UPDATE reservations SET status = 'confirmed', confirmed_at = NOW() WHERE id = ?",
      [reservationId],
    );
    await notify(conn, reservation.beneficiary_id, {
      type: 'reservation_confirmed',
      title: 'Réservation confirmée',
      body: `« ${reservation.offer_title} » vous attend. Code de retrait : ${reservation.pickup_code}.`,
      data: {
        reservation_id: reservation.id,
        offer_id: reservation.offer_id,
        pickup_start: reservation.pickup_start,
        pickup_end: reservation.pickup_end,
      },
    });
  });

  res.json(await reload(reservationId, req.user));
});

// Annulation par le bénéficiaire (compte ou invité muni de son jeton) ou le publieur.
reservationsRouter.patch('/:id/cancel', optionalAuth, async (req, res) => {
  const { id: reservationId } = idParam.parse(req.params);
  let guestHolder = false;

  await transaction(async (conn) => {
    const reservation = await loadReservation(conn, reservationId);
    guestHolder = await isGuestHolder(req, reservation);
    const isBeneficiary =
      guestHolder || (req.user && reservation.beneficiary_id === req.user.id);
    const isDonor = req.user && reservation.donor_id === req.user.id;

    if (!isBeneficiary && !isDonor) throw notFound('Réservation');
    if (!['pending', 'confirmed'].includes(reservation.status)) {
      throw new HttpError(409, `Réservation déjà ${reservation.status}`);
    }

    await conn.query(
      "UPDATE reservations SET status = 'cancelled', cancelled_at = NOW() WHERE id = ?",
      [reservationId],
    );
    await releaseQuantity(conn, reservation);
    await notify(conn, isDonor ? reservation.beneficiary_id : reservation.donor_id, {
      type: 'reservation_cancelled',
      title: 'Réservation annulée',
      body: `La réservation de « ${reservation.offer_title} » a été annulée par ${
        isDonor ? 'le donateur' : 'le bénéficiaire'
      }.`,
      data: { reservation_id: reservation.id, offer_id: reservation.offer_id },
    });
  });

  if (guestHolder) {
    const [reservation] = await query(`${RESERVATION_SELECT} WHERE r.id = ?`, [reservationId]);
    return res.json(reservation);
  }
  res.json(await reload(reservationId, req.user));
});

// Retrait : le publieur saisit le code que lui présente le bénéficiaire.
reservationsRouter.post('/:id/pickup', authenticate, async (req, res) => {
  const { id: reservationId } = idParam.parse(req.params);
  const { pickup_code: pickupCode } = pickupSchema.parse(req.body);

  await transaction(async (conn) => {
    const reservation = await loadReservation(conn, reservationId);
    if (reservation.donor_id !== req.user.id) throw notFound('Réservation');
    if (reservation.status !== 'confirmed') {
      throw new HttpError(409, 'La réservation doit être confirmée avant le retrait');
    }
    if (reservation.pickup_code !== pickupCode) {
      throw new HttpError(400, 'Code de retrait incorrect');
    }

    await conn.query(
      "UPDATE reservations SET status = 'picked_up', picked_up_at = NOW() WHERE id = ?",
      [reservationId],
    );
    await completeOfferIfDone(conn, reservation.offer_id);
    await notify(conn, reservation.beneficiary_id, {
      type: 'pickup_done',
      title: 'Retrait validé',
      body: `Merci ! Vous avez récupéré « ${reservation.offer_title} ».`,
      data: { reservation_id: reservation.id, offer_id: reservation.offer_id },
    });
  });

  res.json(await reload(reservationId, req.user));
});
