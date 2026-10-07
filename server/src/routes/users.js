import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { z } from 'zod';

import { query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { HttpError } from '../http/errors.js';
import { idParam, latitude, longitude } from '../http/validation.js';
import { photoSchema, saveUserPhoto } from '../services/photos.js';
import { BCRYPT_ROUNDS, issueToken, loadProfile, password } from './auth.js';

export const usersRouter = Router();

// Photo de profil, publique comme les photos d'offres (affichée dans les
// messages) : l'URL change à chaque nouvelle photo, d'où un cache long.
usersRouter.get('/:id/photo', async (req, res) => {
  const { id: userId } = idParam.parse(req.params);
  const [photo] = await query(
    `SELECT p.mime, p.data FROM user_photos p JOIN users u ON u.id = p.user_id
     WHERE p.user_id = ? AND u.status = 'active'`,
    [userId],
  );
  if (!photo) throw new HttpError(404, 'Photo introuvable');
  res.set('Cache-Control', 'public, max-age=604800, immutable').type(photo.mime).send(photo.data);
});

usersRouter.use(authenticate);

const userPhotoSchema = z.object({ photo: photoSchema.unwrap().unwrap() });

// Ajoute ou remplace la photo de profil (`data:image/jpeg;base64,…`).
usersRouter.put('/me/photo', async (req, res) => {
  const { photo } = userPhotoSchema.parse(req.body);
  await saveUserPhoto(req.user.id, photo);
  res.json(await loadProfile(req.user.id));
});

usersRouter.delete('/me/photo', async (req, res) => {
  await saveUserPhoto(req.user.id, null);
  res.json(await loadProfile(req.user.id));
});

/** Taille maximale des préférences enregistrées (JSON). */
const MAX_PREFERENCES_BYTES = 16_000;

/**
 * Préférences du compte, fusionnées avec celles déjà enregistrées (une clé
 * à null est supprimée) : `reco` (recommandations), `push_enabled`,
 * `favorites` (offres et recherches favorites)…
 */
const preferencesSchema = z
  .record(z.string().max(40), z.unknown())
  .refine((value) => JSON.stringify(value).length <= MAX_PREFERENCES_BYTES, {
    message: 'Préférences trop volumineuses',
  });

const updateSchema = z
  .object({
    name: z.string().trim().min(2).max(120),
    first_name: z.string().trim().min(2).max(80),
    last_name: z.string().trim().min(2).max(80),
    phone: z
      .string()
      .trim()
      .regex(/^\+?[0-9 ]{8,20}$/, 'Numéro de téléphone invalide')
      .nullable(),
    latitude: latitude.nullable(),
    longitude: longitude.nullable(),
    preferences: preferencesSchema,
  })
  .partial();

const passwordSchema = z.object({
  current_password: z.string().min(1),
  // Mêmes règles qu'à l'inscription (8 caractères, une lettre, un chiffre).
  new_password: password,
});

usersRouter.patch('/me', async (req, res) => {
  const { preferences, ...data } = updateSchema.parse(req.body);

  // Prénom ou nom modifié : le nom affiché suit.
  if (data.first_name || data.last_name) {
    const [current] = await query('SELECT first_name, last_name FROM users WHERE id = ?', [
      req.user.id,
    ]);
    const first = data.first_name ?? current.first_name ?? '';
    const last = data.last_name ?? current.last_name ?? '';
    data.name = `${first} ${last}`.trim();
  }

  const assignments = Object.keys(data).map((field) => `${field} = ?`);
  const params = Object.values(data);
  if (preferences) {
    assignments.push("preferences = JSON_MERGE_PATCH(COALESCE(preferences, '{}'), ?)");
    params.push(JSON.stringify(preferences));
  }
  if (assignments.length > 0) {
    await query(`UPDATE users SET ${assignments.join(', ')} WHERE id = ?`, [
      ...params,
      req.user.id,
    ]);
  }
  res.json(await loadProfile(req.user.id));
});

usersRouter.put('/me/password', async (req, res) => {
  const data = passwordSchema.parse(req.body);
  const [row] = await query('SELECT password_hash FROM users WHERE id = ?', [
    req.user.id,
  ]);

  if (!row.password_hash) {
    throw new HttpError(400, 'Mot de passe géré par Firebase : utilisez « Mot de passe oublié »');
  }
  if (!(await bcrypt.compare(data.current_password, row.password_hash))) {
    throw new HttpError(400, 'Mot de passe actuel incorrect');
  }
  // Les autres sessions du compte sont révoquées ; celle-ci reçoit un
  // nouveau jeton.
  await query(
    'UPDATE users SET password_hash = ?, token_version = token_version + 1 WHERE id = ?',
    [await bcrypt.hash(data.new_password, BCRYPT_ROUNDS), req.user.id],
  );
  res.json({ token: await issueToken(req.user.id) });
});

const deviceSchema = z.object({
  token: z.string().trim().min(20).max(255),
  platform: z.enum(['android', 'ios', 'web', 'macos', 'windows', 'linux']).optional(),
});

// Jeton FCM de l'appareil : les notifications y sont envoyées en push.
// Un jeton passé d'un compte à un autre (même appareil) change de propriétaire.
usersRouter.post('/me/devices', async (req, res) => {
  const data = deviceSchema.parse(req.body);
  await query(
    `INSERT INTO device_tokens (token, user_id, platform) VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE user_id = VALUES(user_id), platform = VALUES(platform)`,
    [data.token, req.user.id, data.platform ?? null],
  );
  res.status(204).end();
});

// Déconnexion : l'appareil ne reçoit plus les notifications du compte.
usersRouter.delete('/me/devices', async (req, res) => {
  const { token } = deviceSchema.pick({ token: true }).parse(req.body);
  await query('DELETE FROM device_tokens WHERE token = ? AND user_id = ?', [token, req.user.id]);
  res.status(204).end();
});
