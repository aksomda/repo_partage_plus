import { query } from '../db/pool.js';

/**
 * Indicateurs d'aide à la décision pour le donateur, offre par offre :
 * risque de gaspillage (0 à 100) et suggestions concrètes. Calculés à partir
 * des données de la plateforme (demande récente par catégorie), sans IA :
 * toujours disponibles, et copiés sur l'appareil pour le mode hors ligne.
 * Les conseils rédigés par l'IA (routes/ai.js) s'appuient dessus.
 */

/** Période d'observation de la demande. */
const DEMAND_DAYS = 30;

const clamp = (value) => Math.max(0, Math.min(1, value));

/** Niveau lisible d'un score de risque. */
export function riskLevel(risk) {
  if (risk >= 60) return 'high';
  if (risk >= 30) return 'medium';
  return 'low';
}

/**
 * Score de risque d'une offre et ses raisons. [demand] : réservations par
 * offre publiée dans la catégorie sur 30 jours (0 = aucune demande).
 */
export function scoreOffer(offer, { demand, now = new Date() }) {
  const hoursLeft = (new Date(offer.pickup_end) - now) / 3_600_000;
  const expiry = new Date(`${offer.expiry_date}T23:59:59Z`);
  const daysToExpiry = (expiry - now) / 86_400_000;
  const remaining = offer.initial_quantity > 0 ? offer.quantity_available / offer.initial_quantity : 0;

  // Plus il reste de produits et moins il reste de temps, plus le risque est grand.
  const urgency = clamp(1 - Math.min(hoursLeft, daysToExpiry * 24) / 72);
  const unsold = clamp(remaining);
  const lowDemand = clamp(1 - demand / 1.5);
  const paid = Number(offer.price) > 0 ? 1 : 0;

  const risk = Math.round(
    100 * (0.4 * urgency * unsold + 0.3 * unsold + 0.2 * lowDemand + 0.1 * paid * unsold),
  );

  const reasons = [];
  const suggestions = [];
  if (urgency >= 0.6 && unsold > 0) {
    reasons.push(
      hoursLeft < 24
        ? `Retrait terminé dans ${Math.max(0, Math.round(hoursLeft))} h`
        : `DLC dans ${Math.max(0, Math.round(daysToExpiry))} jour(s)`,
    );
  }
  if (unsold >= 0.75) reasons.push(`${offer.quantity_available} sur ${offer.initial_quantity} encore disponibles`);
  if (lowDemand >= 0.6) reasons.push(`Peu de demande récente pour « ${offer.category_name} »`);

  if (paid && risk >= 30) suggestions.push('Baissez le prix ou passez en don gratuit');
  if (urgency >= 0.5 && Number(offer.slots_count ?? 1) <= 1) {
    suggestions.push('Ajoutez un créneau de retrait (ex. : en soirée)');
  }
  if (risk >= 60) suggestions.push('Signalez l’offre aux associations proches');
  if (Number(offer.pending_confirmations) > 0) {
    suggestions.push(`Confirmez les ${offer.pending_confirmations} réservation(s) en attente`);
  }
  if (!offer.photo_updated_at && unsold > 0.5) suggestions.push('Ajoutez une photo : elle attire les bénéficiaires');

  return {
    offer_id: offer.id,
    risk,
    level: riskLevel(risk),
    reasons,
    suggestions,
  };
}

/** Indicateurs des offres en cours du donateur (publiées ou épuisées). */
export async function donorInsights(donorId, now = new Date()) {
  const [offers, demandRows] = await Promise.all([
    query(
      `SELECT o.id, o.title, o.category_id, c.name AS category_name, o.price,
              o.initial_quantity, o.quantity_available, o.expiry_date, o.pickup_end,
              o.photo_updated_at,
              (SELECT COUNT(*) FROM offer_slots s WHERE s.offer_id = o.id) AS slots_count,
              (SELECT COUNT(*) FROM reservations r
                WHERE r.offer_id = o.id AND r.status = 'pending') AS pending_confirmations
       FROM offers o JOIN categories c ON c.id = o.category_id
       WHERE o.donor_id = ? AND o.status IN ('published', 'reserved')`,
      [donorId],
    ),
    query(
      `SELECT o.category_id,
              COUNT(DISTINCT o.id) AS offers,
              COUNT(r.id) AS reservations
       FROM offers o
       LEFT JOIN reservations r ON r.offer_id = o.id AND r.status <> 'cancelled'
       WHERE o.created_at >= NOW() - INTERVAL ? DAY
       GROUP BY o.category_id`,
      [DEMAND_DAYS],
    ),
  ]);
  const demand = new Map(
    demandRows.map((row) => [row.category_id, Number(row.reservations) / Math.max(1, Number(row.offers))]),
  );
  return offers
    .map((offer) => ({
      ...scoreOffer(offer, { demand: demand.get(offer.category_id) ?? 0, now }),
      title: offer.title,
    }))
    .sort((a, b) => b.risk - a.risk);
}
