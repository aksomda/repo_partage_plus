import { HttpError } from '../http/errors.js';

/** Nom du publieur : compte, ou prénom et nom saisis par l'invité. */
export const DONOR_NAME = `COALESCE(u.name, CONCAT(o.guest_first_name, ' ', o.guest_last_name))`;

/**
 * Type de publieur pour la recommandation : code de l'acteur du compte
 * (particulier, commercant, restaurateur…), ou `invite` sans compte.
 */
export const PUBLISHER_TYPE = `CASE WHEN o.donor_id IS NULL THEN 'invite' ELSE COALESCE(pa.code, u.role) END`;

/**
 * Chemin de la photo, relatif à l'URL de l'API (NULL sans photo). Le
 * paramètre `v` change à chaque nouvelle photo, pour les caches.
 */
export const PHOTO_PATH = `IF(o.photo_updated_at IS NULL, NULL,
  CONCAT('/offers/', o.id, '/photo?v=', UNIX_TIMESTAMP(o.photo_updated_at)))`;

/**
 * Créneaux de retrait de l'offre : [{ id, start, end }] (dates ISO UTC,
 * ordre non garanti : à trier) ; NULL pour une offre sans créneau
 * enregistré (toute la période).
 */
export const SLOTS_JSON = `(SELECT JSON_ARRAYAGG(JSON_OBJECT(
    'id', s.id,
    'start', DATE_FORMAT(s.start_at, '%Y-%m-%dT%H:%i:%sZ'),
    'end', DATE_FORMAT(s.end_at, '%Y-%m-%dT%H:%i:%sZ')))
  FROM offer_slots s WHERE s.offer_id = o.id)`;

/** Nombre maximal de créneaux par offre. */
export const MAX_SLOTS = 6;

/**
 * Créneaux à enregistrer : ceux envoyés, sinon un seul couvrant toute la
 * période. Renvoie aussi le premier début et la dernière fin.
 */
export function normalizeSlots(data) {
  const slots = (data.slots?.length ? data.slots : [{ start: data.pickup_start, end: data.pickup_end }])
    .map((slot) => ({ start: new Date(slot.start), end: new Date(slot.end) }))
    .sort((a, b) => a.start - b.start);
  return {
    slots,
    pickupStart: slots[0].start,
    pickupEnd: new Date(Math.max(...slots.map((slot) => slot.end.getTime()))),
  };
}

/**
 * Fin du jour de la date limite. En UTC, comme toutes les dates stockées
 * (heure locale du Burkina Faso et des pays voisins).
 */
export function expiryEnd(expiryDate) {
  return new Date(`${expiryDate}T23:59:59.999Z`);
}

/**
 * Dates cohérentes à la publication : date limite pas encore passée, chaque
 * créneau se termine dans le futur, et au plus tard le jour de la date limite
 * (sinon l'offre disparaîtrait aussitôt, ou se retirerait périmée).
 */
export function assertPickupDates(slots, expiryDate, now = new Date()) {
  const limit = expiryEnd(expiryDate);
  if (limit <= now) {
    throw new HttpError(400, 'La date limite est déjà passée', { field: 'expiry_date' });
  }
  if (slots.some((slot) => slot.end <= now)) {
    throw new HttpError(400, 'Chaque créneau de retrait doit se terminer dans le futur', {
      field: 'pickup_end',
      code: 'pickup_in_past',
    });
  }
  if (slots.some((slot) => slot.end > limit)) {
    throw new HttpError(
      400,
      'Le retrait doit se terminer au plus tard le jour de la date limite',
      { field: 'pickup_end', code: 'pickup_after_expiry' },
    );
  }
}

/** Remplace les créneaux de l'offre. */
export async function saveSlots(conn, offerId, slots) {
  await conn.query('DELETE FROM offer_slots WHERE offer_id = ?', [offerId]);
  await conn.query('INSERT INTO offer_slots (offer_id, start_at, end_at) VALUES ?', [
    slots.map((slot) => [offerId, slot.start, slot.end]),
  ]);
}

/**
 * `is_guest` : publiée sans compte ; `contact_phone` : téléphone de l'invité,
 * seul moyen de le joindre (celui d'un compte n'est donné qu'après réservation).
 */
const OFFER_FIELDS = `o.*, c.name AS category_name, c.icon AS category_icon, ${DONOR_NAME} AS donor_name, ${PUBLISHER_TYPE} AS publisher_type,
         o.donor_id IS NULL AS is_guest, o.guest_phone AS contact_phone,
         ${PHOTO_PATH} AS photo_path, ${SLOTS_JSON} AS slots`;

const OFFER_JOINS = `
  FROM offers o
  JOIN categories c ON c.id = o.category_id
  LEFT JOIN users u ON u.id = o.donor_id
  LEFT JOIN actors pa ON pa.id = u.actor_id`;

export const OFFER_SELECT = `SELECT ${OFFER_FIELDS} ${OFFER_JOINS}`;

/** Avec l'e-mail de contact (privé) : réservé au publieur. */
export const OWN_OFFER_SELECT = `SELECT ${OFFER_FIELDS}, oc.email AS contact_email ${OFFER_JOINS}
  LEFT JOIN offer_contacts oc ON oc.offer_id = o.id`;

/** Enregistre (ou efface, si vide) l'e-mail de contact privé de l'offre. */
export async function saveContactEmail(conn, offerId, email) {
  if (email) {
    await conn.query(
      'INSERT INTO offer_contacts (offer_id, email) VALUES (?, ?) ON DUPLICATE KEY UPDATE email = VALUES(email)',
      [offerId, email],
    );
  } else {
    await conn.query('DELETE FROM offer_contacts WHERE offer_id = ?', [offerId]);
  }
}

/**
 * Publieur en mesure de confirmer les réservations : invité, ou compte
 * actif (les offres d'un compte désactivé sont masquées, puis réapparaissent
 * s'il est réactivé).
 */
export const DONOR_ACTIVE = `(o.donor_id IS NULL OR EXISTS (
    SELECT 1 FROM users du WHERE du.id = o.donor_id AND du.status = 'active'))`;

/** Offre visible et réservable par les bénéficiaires. */
export const OFFER_AVAILABLE = `
  o.status = 'published'
  AND o.quantity_available > 0
  AND o.expiry_date >= CURDATE()
  AND o.pickup_end > NOW()
  AND ${DONOR_ACTIVE}`;

/** Distance en km (haversine) entre (?, ?) et l'offre : params [lat, lng, lat]. */
export const DISTANCE_KM = `
  (6371 * ACOS(LEAST(1,
    COS(RADIANS(?)) * COS(RADIANS(o.latitude)) * COS(RADIANS(o.longitude) - RADIANS(?))
    + SIN(RADIANS(?)) * SIN(RADIANS(o.latitude)))))`;
