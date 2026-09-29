export const OFFER_SELECT = `
  SELECT o.*, c.name AS category_name, u.name AS donor_name
  FROM offers o
  JOIN categories c ON c.id = o.category_id
  JOIN users u ON u.id = o.donor_id`;

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
