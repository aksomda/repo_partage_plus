import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { z } from 'zod';

import { query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { HttpError } from '../http/errors.js';
import { latitude, longitude } from '../http/validation.js';
import { loadProfile } from './auth.js';

export const usersRouter = Router();

usersRouter.use(authenticate);

const updateSchema = z
  .object({
    name: z.string().trim().min(2).max(120),
    phone: z.string().trim().max(30).nullable(),
    latitude: latitude.nullable(),
    longitude: longitude.nullable(),
  })
  .partial();

const passwordSchema = z.object({
  current_password: z.string().min(1),
  new_password: z.string().min(8).max(100),
});

usersRouter.patch('/me', async (req, res) => {
  const data = updateSchema.parse(req.body);
  const fields = Object.keys(data);

  if (fields.length > 0) {
    await query(
      `UPDATE users SET ${fields.map((field) => `${field} = ?`).join(', ')} WHERE id = ?`,
      [...fields.map((field) => data[field]), req.user.id],
    );
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
  await query('UPDATE users SET password_hash = ? WHERE id = ?', [
    await bcrypt.hash(data.new_password, 10),
    req.user.id,
  ]);
  res.status(204).end();
});
