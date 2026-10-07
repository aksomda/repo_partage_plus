import { getMessaging } from 'firebase-admin/messaging';

import { query } from '../db/pool.js';
import { firebaseApp } from './firebase.js';

/** Erreurs FCM signalant un jeton périmé : il est supprimé. */
const STALE_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/invalid-argument',
]);

/**
 * Rappel de retrait et DLC proche : déjà programmés sur le téléphone à
 * chaque synchronisation (même hors ligne), pas de push en double.
 */
const PLANNED_ON_DEVICE = new Set(['pickup_reminder', 'expiry_soon']);

/** Envoi réel par Firebase Cloud Messaging ; null si Firebase n'est pas configuré. */
const realSender = {
  async send(tokens, message) {
    const app = firebaseApp();
    if (!app) return null;
    const result = await getMessaging(app).sendEachForMulticast({ tokens, ...message });
    return result.responses.map((response) => response.error?.code ?? null);
  },
};

let sender = realSender;

/** Les valeurs de `data` d'un message FCM doivent être des chaînes. */
function stringData(data) {
  if (!data) return undefined;
  return Object.fromEntries(
    Object.entries(data)
      .filter(([, value]) => value !== null && value !== undefined)
      .map(([key, value]) => [key, value instanceof Date ? value.toISOString() : String(value)]),
  );
}

/**
 * Envoie une notification push à tous les appareils de l'utilisateur. Ne
 * lève jamais d'erreur : la notification reste dans l'application.
 * `always` : envoyée même si l'utilisateur a coupé les push (codes de sécurité).
 */
export async function sendPush(userId, { type, title, body, data }, { always = false } = {}) {
  if (PLANNED_ON_DEVICE.has(type)) return;
  try {
    // Push désactivé par l'utilisateur (profil) : notification dans l'app seulement.
    const rows = await query(
      `SELECT dt.token FROM device_tokens dt JOIN users u ON u.id = dt.user_id
       WHERE dt.user_id = ?
         AND (? OR COALESCE(JSON_UNQUOTE(JSON_EXTRACT(u.preferences, '$.push_enabled')), 'true') <> 'false')`,
      [userId, always],
    );
    if (rows.length === 0) return;
    const tokens = rows.map((row) => row.token);
    const errors = await sender.send(tokens, {
      notification: { title, body },
      data: stringData({ ...data, type }),
      android: { priority: 'high', notification: { channelId: 'rappels' } },
    });
    const stale = tokens.filter((_, index) => STALE_TOKEN_CODES.has(errors?.[index]));
    if (stale.length > 0) {
      await query('DELETE FROM device_tokens WHERE token IN (?)', [stale]);
    }
  } catch (error) {
    console.error('Push non envoyé :', error.message);
  }
}

/** Pour les tests uniquement. `null` rétablit l'envoi réel. */
export function setPushSender(fake) {
  sender = fake ?? realSender;
}
