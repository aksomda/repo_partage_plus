import { Router } from 'express';
import { z } from 'zod';

import { config } from '../config.js';
import { query } from '../db/pool.js';
import { optionalAuth } from '../http/auth.js';
import { HttpError } from '../http/errors.js';
import { id, latitude, longitude } from '../http/validation.js';
import { InputError, LIMITS, ModelError, refineRecommendations } from '../services/ai_refine.js';
import { DISTANCE_KM, OFFER_AVAILABLE, PUBLISHER_TYPE } from '../services/offers.js';

/**
 * IA de recommandation intégrée au serveur : repli de la Cloud Function
 * (Windows, Linux, Firebase non configuré ou indisponible). Les offres et
 * l'historique sont relus dans MySQL : l'application n'envoie que des id.
 */
export const aiRouter = Router();

const text = (max) => z.string().trim().max(max);

const refineSchema = z.object({
  candidates: z
    .array(z.object({ id, local_score: z.coerce.number().min(0).max(100).optional() }))
    .min(1)
    .max(LIMITS.candidates),
  preferences_text: text(LIMITS.text).optional(),
  preferred_categories: z.array(text(80)).max(20).optional(),
  preferred_publishers: z.array(text(40)).max(10).optional(),
  max_price: z.coerce.number().min(0).nullable().optional(),
  max_distance_km: z.coerce.number().positive().max(500).optional(),
  latitude: latitude.optional(),
  longitude: longitude.optional(),
  // Consultations gardées sur l'appareil (les réservations viennent de MySQL).
  recent_titles: z.array(text(LIMITS.title)).max(LIMITS.history).optional(),
});

// ---------- Limite d'appels (coût maîtrisé) ----------

const calls = new Map();

function checkRate(key) {
  const now = Date.now();
  const recent = (calls.get(key) ?? []).filter((at) => now - at < 3_600_000);
  if (recent.length >= config.rodium.callsPerHour) {
    throw new HttpError(429, 'Trop de demandes à l’IA : réessayez plus tard');
  }
  recent.push(now);
  calls.set(key, recent);
}

/** Pour les tests : remplace `fetch` vers RodiumAI, `null` rétablit l'accès réel. */
let fetchImpl = null;
export function setRodiumFetch(fake) {
  fetchImpl = fake;
}

/** Pour les tests : vide les compteurs d'appels. */
export function resetAiRateLimit() {
  calls.clear();
}

// ---------- Route ----------

aiRouter.post('/refine', optionalAuth, async (req, res) => {
  if (!config.rodium.apiKey) {
    throw new HttpError(503, 'IA non configurée sur le serveur', { code: 'ai_not_configured' });
  }
  const data = refineSchema.parse(req.body);
  checkRate(req.user ? `user:${req.user.id}` : `ip:${req.ip}`);

  const ids = [...new Set(data.candidates.map((candidate) => candidate.id))];
  const hasPosition = data.latitude !== undefined && data.longitude !== undefined;

  // Seules les offres encore disponibles sont proposées au modèle.
  const offers = await query(
    `SELECT o.id, o.title, o.price, c.name AS category_name,
            ${PUBLISHER_TYPE} AS publisher_type,
            DATEDIFF(o.expiry_date, CURDATE()) AS days_to_expiry,
            ${hasPosition ? DISTANCE_KM : 'NULL'} AS distance_km
     FROM offers o
     JOIN categories c ON c.id = o.category_id
     LEFT JOIN users u ON u.id = o.donor_id
     LEFT JOIN actors pa ON pa.id = u.actor_id
     WHERE o.id IN (?) AND ${OFFER_AVAILABLE}`,
    [...(hasPosition ? [data.latitude, data.longitude, data.latitude] : []), ids],
  );
  if (offers.length === 0) throw new HttpError(409, 'Aucune de ces offres n’est disponible');

  // Ordre du classement local conservé (le prompt s'appuie dessus).
  const byId = new Map(offers.map((offer) => [offer.id, offer]));
  const localScore = new Map(data.candidates.map((c) => [c.id, c.local_score]));
  const candidates = ids
    .filter((offerId) => byId.has(offerId))
    .map((offerId) => {
      const offer = byId.get(offerId);
      return {
        id: offer.id,
        title: offer.title,
        category: offer.category_name,
        publisher_type: offer.publisher_type,
        distance_km: offer.distance_km,
        days_to_expiry: offer.days_to_expiry,
        price: offer.price,
        local_score: localScore.get(offerId),
      };
    });

  // Historique du compte dans MySQL : réservations et catégories préférées.
  let reserved = [];
  let topCategories = [];
  if (req.user) {
    reserved = await query(
      `SELECT o.title FROM reservations r JOIN offers o ON o.id = r.offer_id
       WHERE r.beneficiary_id = ? AND r.status <> 'cancelled'
       ORDER BY r.created_at DESC LIMIT ?`,
      [req.user.id, LIMITS.history],
    );
    topCategories = await query(
      `SELECT c.name, COUNT(*) AS total FROM reservations r
       JOIN offers o ON o.id = r.offer_id JOIN categories c ON c.id = o.category_id
       WHERE r.beneficiary_id = ? AND r.status <> 'cancelled'
       GROUP BY c.id, c.name ORDER BY total DESC LIMIT 5`,
      [req.user.id],
    );
  }

  try {
    const result = await refineRecommendations(
      {
        candidates,
        preferences_text: data.preferences_text,
        preferred_categories: data.preferred_categories,
        preferred_publishers: data.preferred_publishers,
        max_price: data.max_price,
        max_distance_km: data.max_distance_km,
        history: {
          recent_titles: data.recent_titles,
          reserved_titles: reserved.map((row) => row.title),
          top_categories: topCategories.map((row) => row.name),
        },
      },
      {
        apiKey: config.rodium.apiKey,
        model: config.rodium.model,
        fetchImpl: fetchImpl ?? undefined,
      },
    );
    res.json({ ...result, source: 'server' });
  } catch (error) {
    if (error instanceof InputError) throw new HttpError(400, error.message);
    if (error instanceof ModelError) {
      console.warn('IA indisponible :', error.message);
      throw new HttpError(503, 'Service d’IA indisponible', { code: 'ai_unavailable' });
    }
    throw error;
  }
});
