import jwt from 'jsonwebtoken';

import { config } from '../config.js';
import { query } from '../db/pool.js';
import { HttpError } from './errors.js';

export function signToken(user) {
  return jwt.sign({ sub: String(user.id), role: user.role }, config.jwt.secret, {
    expiresIn: config.jwt.expiresIn,
  });
}

async function userFromRequest(req) {
  const header = req.get('authorization') ?? '';
  if (!header.startsWith('Bearer ')) return null;

  let payload;
  try {
    payload = jwt.verify(header.slice(7), config.jwt.secret);
  } catch {
    throw new HttpError(401, 'Session invalide ou expirée');
  }

  // Relu en base pour appliquer immédiatement une suspension ou un changement de rôle.
  const [user] = await query(
    'SELECT id, name, email, role, status FROM users WHERE id = ?',
    [Number(payload.sub)],
  );
  if (!user) throw new HttpError(401, 'Compte introuvable');
  if (user.status !== 'active') throw new HttpError(403, 'Compte suspendu');
  return user;
}

/** Exige un utilisateur connecté, disponible ensuite dans req.user. */
export async function authenticate(req, res, next) {
  const user = await userFromRequest(req);
  if (!user) throw new HttpError(401, 'Authentification requise');
  req.user = user;
  next();
}

/** Renseigne req.user si un jeton est fourni, sans l'exiger. */
export async function optionalAuth(req, res, next) {
  req.user = await userFromRequest(req);
  next();
}

export function requireRole(...roles) {
  return (req, res, next) => {
    if (!roles.includes(req.user?.role)) {
      throw new HttpError(403, 'Accès refusé pour ce rôle');
    }
    next();
  };
}
