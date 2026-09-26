import jwt from 'jsonwebtoken';

import { config } from '../config.js';
import { query } from '../db/pool.js';
import { HttpError } from './errors.js';

const MUTATING = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
const KEY_FORMAT = /^[\w-]{8,64}$/;

function userIdOf(req) {
  const header = req.get('authorization') ?? '';
  if (!header.startsWith('Bearer ')) return 0;
  try {
    return Number(jwt.verify(header.slice(7), config.jwt.secret).sub);
  } catch {
    return 0;
  }
}

/**
 * Si la requête porte un en-tête Idempotency-Key déjà vu, renvoie la réponse
 * enregistrée au lieu de rejouer l'action. Utilisé par la file d'attente
 * hors ligne de l'application : un envoi interrompu peut être retenté sans risque.
 */
export async function idempotency(req, res, next) {
  const key = req.get('idempotency-key');
  if (!key || !MUTATING.has(req.method)) return next();
  if (!KEY_FORMAT.test(key)) throw new HttpError(400, 'Idempotency-Key invalide');

  const userId = userIdOf(req);
  const path = req.originalUrl.slice(0, 255);
  const [existing] = await query(
    'SELECT * FROM idempotency_keys WHERE idem_key = ? AND user_id = ?',
    [key, userId],
  );

  if (existing) {
    if (existing.method !== req.method || existing.path !== path) {
      throw new HttpError(422, 'Idempotency-Key déjà utilisée pour une autre requête');
    }
    if (existing.status_code === null) {
      // Premier envoi encore en cours : l'application réessaiera plus tard.
      res.set('Retry-After', '2');
      throw new HttpError(503, 'Requête déjà en cours de traitement');
    }
    res.set('Idempotent-Replayed', 'true').status(existing.status_code);
    return existing.response_body === null ? res.end() : res.json(existing.response_body);
  }

  try {
    await query(
      'INSERT INTO idempotency_keys (idem_key, user_id, method, path) VALUES (?, ?, ?, ?)',
      [key, userId, req.method, path],
    );
  } catch (error) {
    if (error.code === 'ER_DUP_ENTRY') {
      res.set('Retry-After', '2');
      throw new HttpError(503, 'Requête déjà en cours de traitement');
    }
    throw error;
  }

  let body = null;
  const json = res.json.bind(res);
  res.json = (payload) => {
    body = payload;
    return json(payload);
  };

  res.on('finish', () => {
    // Erreur serveur ou session expirée : la clé est libérée pour permettre un nouvel essai.
    const retryable = res.statusCode >= 500 || res.statusCode === 401;
    const save = retryable
      ? query('DELETE FROM idempotency_keys WHERE idem_key = ? AND user_id = ?', [key, userId])
      : query(
          'UPDATE idempotency_keys SET status_code = ?, response_body = ? WHERE idem_key = ? AND user_id = ?',
          [res.statusCode, body === null ? null : JSON.stringify(body), key, userId],
        );
    save.catch((error) => console.error('Idempotency-Key non enregistrée :', error.message));
  });

  next();
}
