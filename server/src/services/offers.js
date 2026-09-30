/** Nom du publieur : compte, ou prénom et nom saisis par l'invité. */
export const DONOR_NAME = `COALESCE(u.name, CONCAT(o.guest_first_name, ' ', o.guest_last_name))`;

/**
 * Type de publieur pour la recommandation : code de l'acteur du compte
 * (particulier, commercant, restaurateur…), ou `invite` sans compte.
 */
export const PUBLISHER_TYPE = `CASE WHEN o.donor_id IS NULL THEN 'invite' ELSE COALESCE(pa.code, u.role) END`;

/**
 * `is_guest` : publiée sans compte ; `contact_phone` : téléphone de l'invité,
 * seul moyen de le joindre (celui d'un compte n'est donné qu'après réservation).
 */
export const OFFER_SELECT = `
  SELECT o.*, c.name AS category_name, c.icon AS category_icon, ${DONOR_NAME} AS donor_name, ${PUBLISHER_TYPE} AS publisher_type,
         o.donor_id IS NULL AS is_guest, o.guest_phone AS contact_phone
  FROM offers o
  JOIN categories c ON c.id = o.category_id
  LEFT JOIN users u ON u.id = o.donor_id
  LEFT JOIN actors pa ON pa.id = u.actor_id`;

/** Offre visible et réservable par les bénéficiaires. */
export const OFFER_AVAILABLE = `
  o.status = 'published'
  AND o.quantity_available > 0
  AND o.expiry_date >= CURDATE()
  AND o.pickup_end > NOW()`;

/** Distance en km (haversine) entre (?, ?) et l'offre : params [lat, lng, lat]. */
export const DISTANCE_KM = `
  (6371 * ACOS(LEAST(1,
    COS(RADIANS(?)) * COS(RADIANS(o.latitude)) * COS(RADIANS(o.longitude) - RADIANS(?))
    + SIN(RADIANS(?)) * SIN(RADIANS(o.latitude)))))`;
