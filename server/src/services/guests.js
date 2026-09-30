import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

import { z } from 'zod';

import { HttpError } from '../http/errors.js';

/** Identité saisie par un invité (publication ou réservation sans compte). */
export const guestSchema = z.object({
  first_name: z.string().trim().min(2).max(80),
  last_name: z.string().trim().min(2).max(80),
  phone: z
    .string()
    .trim()
    .regex(/^\+?[0-9 ]{8,20}$/, 'Numéro de téléphone invalide'),
});

const hash = (token) => createHash('sha256').update(token).digest('hex');

/**
 * Crée le jeton qui permettra à l'invité de retrouver sa publication ou sa
 * réservation depuis son appareil. Renvoyé une seule fois, stocké haché.
 */
export async function issueGuestToken(conn, kind, targetId) {
  const token = randomBytes(24).toString('base64url');
  await conn.query('INSERT INTO guest_tokens (kind, target_id, token_hash) VALUES (?, ?, ?)', [
    kind,
    targetId,
    hash(token),
  ]);
  return token;
}

/** Jeton envoyé par l'application dans l'en-tête X-Guest-Token. */
export function guestTokenOf(req) {
  const token = req.get('x-guest-token');
  return token && token.length <= 100 ? token : null;
}

/** true si [token] ouvre l'accès à cet élément. */
export async function hasGuestAccess(db, kind, targetId, token) {
  if (!token) return false;
  const [[row]] = await db.query(
    'SELECT token_hash FROM guest_tokens WHERE kind = ? AND target_id = ?',
    [kind, targetId],
  );
  if (!row) return false;
  return timingSafeEqual(Buffer.from(row.token_hash, 'hex'), Buffer.from(hash(token), 'hex'));
}

/**
 * Limite le nombre de publications / réservations sans compte par adresse IP,
 * pour freiner le spam (compteur en mémoire, remis à zéro au redémarrage).
 */
export function guestRateLimit({ max, windowMinutes = 60 }) {
  const hits = new Map();
  return (req, res, next) => {
    if (req.user) return next();
    const now = Date.now();
    const since = now - windowMinutes * 60_000;
    const recent = (hits.get(req.ip) ?? []).filter((time) => time > since);
    if (recent.length >= max) {
      throw new HttpError(429, 'Trop de demandes sans compte : réessayez plus tard ou connectez-vous');
    }
    recent.push(now);
    hits.set(req.ip, recent);
    next();
  };
}

/** Prénom Nom affiché pour un invité. */
export const guestName = (guest) => `${guest.first_name} ${guest.last_name}`;
