import { query, transaction } from '../db/pool.js';
import { notify } from './notifications.js';

/**
 * Alertes « nouvelle offre » : à la publication, chaque compte dont une
 * recherche enregistrée (préférences `favorites.searches`) correspond est
 * notifié dans l'application et en push, application fermée comprise. Mêmes
 * critères que l'application (features/favorites/data/favorites.dart).
 */

/** Distance en km entre deux points (haversine). */
function haversineKm(lat1, lng1, lat2, lng2) {
  const rad = (degrees) => (degrees * Math.PI) / 180;
  const a =
    Math.sin(rad(lat2 - lat1) / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lng2 - lng1) / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** Date limite aujourd'hui ou demain (UTC). */
function expiresSoon(expiryDate, now) {
  const tomorrow = new Date(now.getTime() + 86_400_000).toISOString().slice(0, 10);
  return String(expiryDate).slice(0, 10) <= tomorrow;
}

/**
 * La recherche [search] répond à l'offre ; [position] : position du compte
 * (sans position, le rayon est ignoré).
 */
export function searchMatches(search, offer, position, now = new Date()) {
  if (search.category_id != null && Number(search.category_id) !== offer.category_id) {
    return false;
  }
  const price = Number(offer.price ?? 0);
  if (search.price === 'free' && price !== 0) return false;
  if (search.price === 'paid' && price <= 0) return false;
  if (search.urgent_only === true && !expiresSoon(offer.expiry_date, now)) return false;

  const text = String(search.text ?? '').trim().toLowerCase();
  if (text) {
    const found = [offer.title, offer.description, offer.category_name].some(
      (value) => typeof value === 'string' && value.toLowerCase().includes(text),
    );
    if (!found) return false;
  }

  // Rayon absent (null) : illimité.
  if (position.latitude == null || position.longitude == null || search.radius_km == null) {
    return true;
  }
  const radius = Number(search.radius_km);
  return (
    haversineKm(
      Number(position.latitude),
      Number(position.longitude),
      Number(offer.latitude),
      Number(offer.longitude),
    ) <= radius
  );
}

/**
 * Notifie les comptes dont une recherche enregistrée correspond à l'offre
 * publiée (sauf son publieur et ceux qui ont coupé ces alertes). Renvoie le
 * nombre de comptes prévenus.
 */
export async function notifySearchMatches(offer) {
  const users = await query(
    `SELECT id, latitude, longitude,
            JSON_EXTRACT(preferences, '$.favorites.searches') AS searches,
            JSON_EXTRACT(preferences, '$.search_alerts') AS search_alerts
     FROM users
     WHERE status = 'active' AND role <> 'admin'
       AND JSON_LENGTH(preferences, '$.favorites.searches') > 0
       AND id <> ?`,
    [offer.donor_id ?? 0],
  );

  const matches = [];
  const parse = (value) => (typeof value === 'string' ? JSON.parse(value) : value);
  for (const user of users) {
    // Alertes coupées dans le profil.
    if (parse(user.search_alerts) === false) continue;
    const searches = parse(user.searches);
    const search = (Array.isArray(searches) ? searches : []).find(
      (candidate) => candidate && searchMatches(candidate, offer, user),
    );
    if (search) matches.push({ userId: user.id, name: search.name });
  }
  if (matches.length === 0) return 0;

  await transaction(async (conn) => {
    for (const { userId, name } of matches) {
      await notify(conn, userId, {
        type: 'search_match',
        title: `Nouvelle offre · ${name}`,
        body: `« ${offer.title} » correspond à votre recherche.`,
        data: { offer_id: offer.id },
      });
    }
  });
  return matches.length;
}
