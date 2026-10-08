import { Router } from 'express';
import { z } from 'zod';

import { config } from '../config.js';
import { query } from '../db/pool.js';
import { authenticate, optionalAuth } from '../http/auth.js';
import { HttpError } from '../http/errors.js';
import { id, latitude, longitude } from '../http/validation.js';
import {
  callRodium,
  InputError,
  LIMITS,
  ModelError,
  refineRecommendations,
} from '../services/ai_refine.js';
import { donorInsights } from '../services/insights.js';
import {
  decodeAudio,
  filterOffers,
  transcribe,
  VOICE_LIMITS,
  VoiceAiError,
} from '../services/voice_search.js';
import { buildDraftMessages, DRAFT_LIMITS, parseDraft } from '../services/offer_draft.js';
import { DISTANCE_KM, OFFER_AVAILABLE, PUBLISHER_TYPE } from '../services/offers.js';
import { buildDashboard } from './impact.js';

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

/** Pour les tests : remplace `fetch` vers l'IA vocale ; `null` : accès réel. */
let voiceFetch = null;
export function setVoiceFetch(fake) {
  voiceFetch = fake;
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

// ---------- Recherche à la voix (IA ouverte) ----------

const voiceSchema = z
  .object({
    // Enregistrement « data:audio/…;base64,… » (AAC, WAV, WebM/Opus…).
    audio: z.string().max(Math.ceil((VOICE_LIMITS.audioBytes * 4) / 3) + 60).optional(),
    text: text(VOICE_LIMITS.text).optional(),
    candidates: z
      .array(
        z.object({
          id,
          distance_km: z.coerce.number().min(0).max(20_000).nullable().optional(),
        }),
      )
      .min(1)
      .max(VOICE_LIMITS.candidates),
  })
  .refine((data) => Boolean(data.audio) || Boolean(data.text), {
    message: 'Demande vide : parlez ou écrivez ce que vous cherchez',
    path: ['text'],
  });

/**
 * Retranscrit la demande dictée (Whisper) puis ne garde que les offres qui y
 * répondent (modèle de langage). Les offres sont relues dans MySQL :
 * l'application n'envoie que des id et des distances.
 */
aiRouter.post('/voice-search', optionalAuth, async (req, res) => {
  const settings = config.voiceAi;
  if (!settings.apiKey) {
    throw new HttpError(503, 'IA vocale non configurée sur le serveur', {
      code: 'voice_ai_not_configured',
    });
  }
  const data = voiceSchema.parse(req.body);
  const audio = data.audio ? decodeAudio(data.audio) : null;
  if (data.audio && !audio) {
    throw new HttpError(400, 'Enregistrement invalide (format audio non reconnu)', {
      field: 'audio',
    });
  }
  if (audio && audio.buffer.length > VOICE_LIMITS.audioBytes) {
    throw new HttpError(400, 'Enregistrement trop long', { field: 'audio' });
  }
  checkRate(req.user ? `voice:user:${req.user.id}` : `voice:ip:${req.ip}`);

  const ids = [...new Set(data.candidates.map((candidate) => candidate.id))];
  const distance = new Map(data.candidates.map((c) => [c.id, c.distance_km ?? null]));
  const offers = await query(
    `SELECT o.id, o.title, o.description, o.price, o.unit, o.expiry_date,
            c.name AS category_name, ${PUBLISHER_TYPE} AS publisher_type
     FROM offers o
     JOIN categories c ON c.id = o.category_id
     LEFT JOIN users u ON u.id = o.donor_id
     LEFT JOIN actors pa ON pa.id = u.actor_id
     WHERE o.id IN (?) AND ${OFFER_AVAILABLE}`,
    [ids],
  );
  const byId = new Map(offers.map((offer) => [offer.id, offer]));
  const candidates = ids
    .filter((offerId) => byId.has(offerId))
    .map((offerId) => {
      const offer = byId.get(offerId);
      return {
        id: offer.id,
        titre: offer.title,
        description: offer.description ? offer.description.slice(0, 160) : undefined,
        categorie: offer.category_name,
        prix_fcfa: Number(offer.price ?? 0),
        unite: offer.unit,
        date_limite: offer.expiry_date,
        publieur: offer.publisher_type,
        distance_km: distance.get(offerId) ?? undefined,
      };
    });

  const fetchImpl = voiceFetch ?? fetch;
  try {
    const transcript = audio
      ? await transcribe({ audio, settings, fetchImpl })
      : data.text;
    const result =
      candidates.length === 0
        ? { keepIds: [], summary: null }
        : await filterOffers({ request: transcript, candidates, settings, fetchImpl });
    res.json({
      transcript,
      keep_ids: result.keepIds,
      summary: result.summary,
      engine: settings.label,
    });
  } catch (error) {
    if (error instanceof VoiceAiError) {
      console.warn('IA vocale indisponible :', error.message);
      throw new HttpError(503, 'Service d’IA vocale indisponible', {
        code: 'voice_ai_unavailable',
      });
    }
    throw error;
  }
});

// ---------- Conseils au donateur ----------

/** Conseil sans IA, à partir des indicateurs (repli toujours disponible). */
export function ruleAdvice(insights, impact) {
  if (insights.length === 0) {
    return impact.pickups > 0
      ? `Merci : ${impact.food_kg} kg de nourriture sauvés grâce à vous. Publiez vos prochains invendus dès qu’ils sont connus.`
      : 'Publiez vos invendus dès qu’ils sont connus : plus le créneau est long, plus ils trouvent preneur.';
  }
  const [worst] = insights;
  const tip = worst.suggestions[0] ?? 'Gardez un créneau de retrait large';
  return `« ${worst.title} » présente le risque de gaspillage le plus élevé (${worst.risk}/100). ${tip}.`;
}

const ADVICE_SYSTEM = `Tu aides un donateur d'une application anti-gaspillage alimentaire en Afrique de l'Ouest (Burkina Faso).
À partir des indicateurs fournis (risque de gaspillage de ses offres, raisons, suggestions, impact déjà obtenu), rédige en français
un conseil court et concret : 3 phrases au maximum, sans liste ni titre, sans inventer de chiffres absents des données.`;

// Conseil personnalisé rédigé par l'IA ; IA absente ou en panne : conseil
// calculé par règles (jamais d'erreur pour l'utilisateur).
aiRouter.post('/advice', authenticate, async (req, res) => {
  const [insights, dashboard] = await Promise.all([
    donorInsights(req.user.id),
    buildDashboard(req.user.id),
  ]);
  const fallback = { advice: ruleAdvice(insights, dashboard.impact), source: 'rules', insights };
  if (!config.rodium.apiKey) return res.json(fallback);

  try {
    checkRate(`advice:${req.user.id}`);
    const content = await callRodium({
      apiKey: config.rodium.apiKey,
      model: config.rodium.model,
      fetchImpl: fetchImpl ?? undefined,
      messages: [
        { role: 'system', content: ADVICE_SYSTEM },
        {
          role: 'user',
          content: JSON.stringify({
            offres: insights.slice(0, 10).map((insight) => ({
              titre: insight.title,
              risque: insight.risk,
              raisons: insight.reasons,
              suggestions: insight.suggestions,
            })),
            impact: dashboard.impact,
            social: dashboard.impact_social,
          }),
        },
      ],
    });
    const advice = typeof content === 'string' ? content.trim().slice(0, 600) : '';
    res.json(advice ? { advice, source: 'ai', insights } : fallback);
  } catch (error) {
    if (!(error instanceof ModelError) && !(error instanceof HttpError)) throw error;
    console.warn('Conseil IA indisponible :', error.message);
    res.json(fallback);
  }
});

// ---------- Publication express (restaurateurs) ----------

const draftSchema = z.object({
  text: z.string().trim().min(5, 'Décrivez votre offre en quelques mots').max(DRAFT_LIMITS.text),
  // Heure de l'appareil (« avant 20h », « ce soir ») : le serveur ignore son fuseau.
  local_time: z
    .string()
    .regex(/^([01]\d|2[0-3]):[0-5]\d$/)
    .optional(),
});

/** Réservé aux comptes dont l'acteur est « restaurateur ». */
async function requireRestaurateur(req) {
  const [row] = await query(
    'SELECT a.code FROM users u LEFT JOIN actors a ON a.id = u.actor_id WHERE u.id = ?',
    [req.user.id],
  );
  if (row?.code !== 'restaurateur') {
    throw new HttpError(403, 'Publication express réservée aux restaurateurs');
  }
}

// Brouillon d'offre à partir d'une description libre ; rien n'est publié.
// IA absente ou en panne : 503, le formulaire classique reste utilisable.
aiRouter.post('/offer-draft', authenticate, async (req, res) => {
  await requireRestaurateur(req);
  const data = draftSchema.parse(req.body);
  if (!config.rodium.apiKey) {
    throw new HttpError(503, 'IA non configurée sur le serveur', { code: 'ai_not_configured' });
  }
  checkRate(`draft:${req.user.id}`);

  const categories = await query('SELECT id, name FROM categories ORDER BY name');
  try {
    const content = await callRodium({
      apiKey: config.rodium.apiKey,
      model: config.rodium.model,
      fetchImpl: fetchImpl ?? undefined,
      messages: buildDraftMessages({
        text: data.text,
        categories,
        localTime: data.local_time,
      }),
    });
    const draft = parseDraft(
      content,
      categories.map((category) => category.id),
    );
    res.json({ draft, source: 'ai' });
  } catch (error) {
    if (!(error instanceof ModelError)) throw error;
    console.warn('Brouillon IA indisponible :', error.message);
    throw new HttpError(503, 'Service d’IA indisponible', { code: 'ai_unavailable' });
  }
});
