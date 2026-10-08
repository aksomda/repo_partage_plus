import jwt from 'jsonwebtoken';

import { config } from '../config.js';
import { isDatabaseUnavailable, query } from '../db/pool.js';
import { firestoreMirror } from '../services/firestore_mirror.js';
import { HttpError } from './errors.js';

/** Seul algorithme accepté : un jeton signé autrement (ou « none ») est refusé. */
const ALGORITHM = 'HS256';

/**
 * `ver` : version des sessions du compte (users.token_version), augmentée à
 * chaque changement de mot de passe ou suspension : les anciens jetons
 * cessent alors de fonctionner.
 */
export function signToken(user) {
  return jwt.sign(
    { sub: String(user.id), role: user.role, ver: Number(user.token_version ?? 0) },
    config.jwt.secret,
    { algorithm: ALGORITHM, expiresIn: config.jwt.expiresIn },
  );
}

/** Contenu d'un jeton valide ; lève une erreur sinon. */
export function verifyToken(token) {
  return jwt.verify(token, config.jwt.secret, { algorithms: [ALGORITHM] });
}

/** Identifiant du compte d'un jeton valide (0 : pas de jeton, ou invalide). */
export function tokenUserId(req) {
  const header = req.get('authorization') ?? '';
  if (!header.startsWith('Bearer ')) return 0;
  try {
    return Number(verifyToken(header.slice(7)).sub) || 0;
  } catch {
    return 0;
  }
}

async function userFromRequest(req) {
  const header = req.get('authorization') ?? '';
  if (!header.startsWith('Bearer ')) return null;

  let payload;
  try {
    payload = verifyToken(header.slice(7));
  } catch {
    throw new HttpError(401, 'Session invalide ou expirée');
  }

  // Relu en base pour appliquer immédiatement une suspension ou un changement de rôle.
  const user = await loadUser(Number(payload.sub));
  if (!user) throw new HttpError(401, 'Compte introuvable');
  // Mot de passe changé ou compte suspendu depuis : jeton révoqué.
  if (user.token_version !== undefined && Number(payload.ver ?? 0) !== user.token_version) {
    throw new HttpError(401, 'Session expirée : reconnectez-vous');
  }
  if (user.status === 'pending') throw new HttpError(403, 'Compte non activé');
  if (user.status !== 'active') throw new HttpError(403, 'Compte désactivé');
  return user;
}

/**
 * Compte lu dans MySQL ; MySQL indisponible : copie Firestore du compte
 * (même statut, pour que les lectures de secours restent protégées).
 */
async function loadUser(id) {
  try {
    const [user] = await query(
      'SELECT id, name, email, role, status, token_version FROM users WHERE id = ?',
      [id],
    );
    return user;
  } catch (error) {
    if (!isDatabaseUnavailable(error)) throw error;
    const copy = await firestoreMirror.readUser(id).catch(() => null);
    if (!copy) throw error;
    const { name, email, role, status } = copy;
    // Copie antérieure à la colonne : version non vérifiable.
    const tokenVersion =
      copy.token_version === undefined ? undefined : Number(copy.token_version);
    return { id, name, email, role, status, token_version: tokenVersion, fromCopy: true };
  }
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
