import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { z } from 'zod';

import { pool, query, transaction } from '../db/pool.js';
import { authenticate, signToken } from '../http/auth.js';
import { HttpError } from '../http/errors.js';
import { id, latitude, longitude } from '../http/validation.js';
import { firebase } from '../services/firebase.js';
import { consumeActivationCode, issueActivationCode } from '../services/otp.js';

export const authRouter = Router();

const email = z.string().trim().toLowerCase().email().max(190);
const idToken = z.string().min(20).max(5000);

/**
 * Inscription, deux modes :
 * - Firebase : le compte (email + mot de passe) est déjà créé par
 *   l'application, qui envoie son jeton ; l'email est lu dans ce jeton ;
 * - compte local (Firebase indisponible, ex. Windows/Linux sans Firebase) :
 *   email + mot de passe envoyés à l'API, mot de passe haché dans MySQL.
 */
const password = z
  .string()
  .min(8, '8 caractères minimum')
  .max(100)
  .regex(/[0-9]/, 'Au moins un chiffre')
  .regex(/[A-Za-z]/, 'Au moins une lettre');

const registerSchema = z.object({
  id_token: idToken.optional(),
  email: email.optional(),
  password: password.optional(),
  first_name: z.string().trim().min(2).max(80),
  last_name: z.string().trim().min(2).max(80),
  gender: z.enum(['male', 'female']),
  age: z.coerce.number().int().min(13, 'Âge minimum : 13 ans').max(120),
  phone: z
    .string()
    .trim()
    .regex(/^\+?[0-9 ]{8,20}$/, 'Numéro de téléphone invalide'),
  actor_id: id,
  latitude: latitude.optional(),
  longitude: longitude.optional(),
  association: z
    .object({
      name: z.string().trim().min(2).max(150),
      registration_number: z.string().trim().max(80).optional(),
      address: z.string().trim().max(255).optional(),
    })
    .optional(),
});

const registerModeSchema = registerSchema.refine(
  (data) => (data.id_token ? !data.password : Boolean(data.email && data.password)),
  { message: 'Jeton Firebase, ou adresse e-mail et mot de passe, requis', path: ['id_token'] },
);

const verifySchema = z.object({ email, code: z.string().trim().regex(/^\d{6}$/, 'Code à 6 chiffres') });
const loginSchema = z.object({ email, password: z.string().min(1) });

export function publicUser(row) {
  const { password_hash: _passwordHash, ...user } = row;
  return user;
}

export async function loadProfile(userId) {
  const [user] = await query(
    `SELECT u.*, a.code AS actor_code, a.label AS actor_label
     FROM users u LEFT JOIN actors a ON a.id = u.actor_id WHERE u.id = ?`,
    [userId],
  );
  const [association] = await query(
    'SELECT id, name, registration_number, address, status, review_reason, reviewed_at FROM associations WHERE user_id = ?',
    [userId],
  );
  return { ...publicUser(user), association: association ?? null };
}

/** Refuse la connexion d'un compte non activé ou suspendu. */
function assertCanLogin(row) {
  if (row.status === 'pending') {
    throw new HttpError(403, 'Compte non activé : saisissez le code reçu par e-mail', {
      code: 'account_pending',
      email: row.email,
    });
  }
  if (row.status !== 'active') {
    throw new HttpError(403, 'Compte désactivé par l’administrateur', {
      code: 'account_suspended',
      reason: row.status_reason,
    });
  }
}

async function session(res, userId) {
  const user = await loadProfile(userId);
  res.json({ token: signToken(user), user });
}

authRouter.post('/register', async (req, res) => {
  const data = registerModeSchema.parse(req.body);
  const identity = data.id_token
    ? await firebase.verifyIdToken(data.id_token)
    : { uid: null, email: data.email };
  if (!identity.email) throw new HttpError(400, 'Le compte Firebase n’a pas d’adresse e-mail');
  const passwordHash = data.password ? await bcrypt.hash(data.password, 10) : null;

  const [actor] = await query('SELECT * FROM actors WHERE id = ?', [data.actor_id]);
  if (!actor || !actor.active || !actor.self_signup) {
    throw new HttpError(400, 'Acteur non disponible à l’inscription');
  }
  if (actor.permission_role === 'association' && !data.association) {
    throw new HttpError(400, 'Informations de l’association requises', {
      field: 'association',
    });
  }

  const userId = await transaction(async (conn) => {
    const [[existing]] = await conn.query('SELECT * FROM users WHERE email = ? FOR UPDATE', [
      identity.email,
    ]);
    // Nouvelle tentative après un échec (e-mail non reçu…) : on met à jour,
    // si c'est bien le même compte (même compte Firebase, ou même mot de passe).
    const sameAccount = identity.uid
      ? existing?.firebase_uid === identity.uid
      : Boolean(
          existing?.password_hash &&
            (await bcrypt.compare(data.password, existing.password_hash)),
        );
    const retry = existing && existing.status === 'pending' && sameAccount;
    if (existing && !retry) {
      throw new HttpError(409, 'Un compte existe déjà avec cette adresse e-mail');
    }

    const fields = {
      name: `${data.first_name} ${data.last_name}`,
      first_name: data.first_name,
      last_name: data.last_name,
      gender: data.gender,
      age: data.age,
      email: identity.email,
      firebase_uid: identity.uid,
      password_hash: passwordHash,
      role: actor.permission_role,
      actor_id: actor.id,
      phone: data.phone,
      latitude: data.latitude ?? null,
      longitude: data.longitude ?? null,
      status: 'pending',
    };

    let newId;
    if (retry) {
      await conn.query('UPDATE users SET ? WHERE id = ?', [fields, existing.id]);
      await conn.query('DELETE FROM associations WHERE user_id = ?', [existing.id]);
      newId = existing.id;
    } else {
      const [result] = await conn.query('INSERT INTO users SET ?', [fields]);
      newId = result.insertId;
    }

    if (actor.permission_role === 'association') {
      await conn.query(
        'INSERT INTO associations (user_id, name, registration_number, address) VALUES (?, ?, ?, ?)',
        [
          newId,
          data.association.name,
          data.association.registration_number ?? null,
          data.association.address ?? null,
        ],
      );
    }

    // Dans la transaction : si l'e-mail ne part pas, rien n'est enregistré.
    await issueActivationCode(conn, { id: newId, ...fields });
    return newId;
  });

  const user = await loadProfile(userId);
  res.status(201).json({ user });
});

/** Activation du compte avec le code à 6 chiffres reçu par e-mail. */
authRouter.post('/verify-email', async (req, res) => {
  const data = verifySchema.parse(req.body);
  const [row] = await query('SELECT * FROM users WHERE email = ?', [data.email]);
  if (!row) throw new HttpError(400, 'Code incorrect');
  if (row.status !== 'pending') {
    throw new HttpError(409, 'Ce compte est déjà activé : connectez-vous');
  }

  // Hors transaction : un essai raté doit rester compté.
  await consumeActivationCode(pool, row.id, data.code);
  await query(
    "UPDATE users SET status = 'active', email_verified_at = NOW() WHERE id = ? AND status = 'pending'",
    [row.id],
  );
  await firebase.syncEmailVerified(row.firebase_uid);

  await session(res, row.id);
});

/** Renvoie un code ; répond 204 même si l'e-mail est inconnu. */
authRouter.post('/resend-code', async (req, res) => {
  const data = z.object({ email }).parse(req.body);
  const [row] = await query('SELECT * FROM users WHERE email = ?', [data.email]);
  if (row?.status === 'pending') {
    await transaction((conn) => issueActivationCode(conn, row));
  }
  res.status(204).end();
});

/** Connexion : l'application s'est connectée à Firebase et envoie son jeton. */
authRouter.post('/firebase', async (req, res) => {
  const data = z.object({ id_token: idToken }).parse(req.body);
  const identity = await firebase.verifyIdToken(data.id_token);

  // Pas de rattachement par e-mail : l'e-mail d'un compte Firebase n'est pas
  // vérifié à sa création et permettrait de prendre le profil d'un autre.
  const [row] = await query('SELECT * FROM users WHERE firebase_uid = ?', [identity.uid]);
  if (!row) {
    throw new HttpError(404, 'Aucun profil pour ce compte : terminez l’inscription', {
      code: 'profile_missing',
    });
  }

  assertCanLogin(row);
  await session(res, row.id);
});

/** Connexion par mot de passe, pour les comptes de démo créés sans Firebase. */
authRouter.post('/login', async (req, res) => {
  const data = loginSchema.parse(req.body);
  const [row] = await query('SELECT * FROM users WHERE email = ?', [data.email]);

  if (
    !row ||
    !row.password_hash ||
    !(await bcrypt.compare(data.password, row.password_hash))
  ) {
    throw new HttpError(401, 'Email ou mot de passe incorrect');
  }
  assertCanLogin(row);
  await session(res, row.id);
});

authRouter.get('/me', authenticate, async (req, res) => {
  res.json(await loadProfile(req.user.id));
});
