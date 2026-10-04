import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';

import { z } from 'zod';

import { query } from '../db/pool.js';
import { HttpError } from '../http/errors.js';
import { loadSettings } from './settings.js';

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

const QUOTA_WORDING = {
  offer: { setting: 'guest_offer', noun: 'publication', action: 'publier' },
  reservation: { setting: 'guest_reservation', noun: 'réservation', action: 'réserver' },
};

/** Numéro réduit aux chiffres (et +), pour compter un même numéro ensemble. */
const normalizePhone = (phone) => phone.replace(/[^0-9+]/g, '');

function formatWindow(hours) {
  if (hours % 24 !== 0) return hours === 1 ? 'heure' : `${hours} heures`;
  const days = hours / 24;
  if (days === 1) return 'jour';
  if (days === 7) return 'semaine';
  return `${days} jours`;
}

/**
 * Quota d'actions sans compte réglé par l'administrateur : compté sur la
 * période, par numéro de téléphone et par adresse IP (le premier atteint bloque).
 */
export async function assertGuestQuota(kind, phone, ip) {
  const { setting, noun, action } = QUOTA_WORDING[kind];
  const settings = await loadSettings();
  const max = settings[`${setting}_max`];
  const hours = settings[`${setting}_window_hours`];

  if (max === 0) {
    throw new HttpError(403, `Impossible de ${action} sans compte : créez un compte`, {
      code: 'guest_disabled',
    });
  }

  const [{ count }] = await query(
    `SELECT COUNT(*) AS count FROM guest_submissions
     WHERE kind = ? AND created_at > NOW() - INTERVAL ? HOUR AND (phone = ? OR ip = ?)`,
    [kind, hours, normalizePhone(phone), ip ?? ''],
  );
  if (count >= max) {
    const plural = max > 1 ? 's' : '';
    throw new HttpError(
      429,
      `Limite de ${max} ${noun}${plural} sans compte par ${formatWindow(hours)} atteinte : ` +
        `créez un compte pour ${action} davantage`,
      { code: 'guest_limit', max, window_hours: hours },
    );
  }
}

/** Compte l'action dans le quota (dans la transaction qui l'enregistre). */
export async function recordGuestSubmission(conn, kind, phone, ip) {
  await conn.query('INSERT INTO guest_submissions (kind, phone, ip) VALUES (?, ?, ?)', [
    kind,
    normalizePhone(phone),
    ip ?? null,
  ]);
}

/** Prénom Nom affiché pour un invité. */
export const guestName = (guest) => `${guest.first_name} ${guest.last_name}`;
