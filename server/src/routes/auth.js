import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { z } from 'zod';

import { query, transaction } from '../db/pool.js';
import { authenticate, signToken } from '../http/auth.js';
import { HttpError } from '../http/errors.js';
import { latitude, longitude } from '../http/validation.js';

export const authRouter = Router();

const email = z.string().trim().toLowerCase().email().max(190);

const registerSchema = z
  .object({
    name: z.string().trim().min(2).max(120),
    email,
    password: z.string().min(8).max(100),
    role: z.enum(['donor', 'beneficiary', 'association']),
    phone: z.string().trim().max(30).optional(),
    latitude: latitude.optional(),
    longitude: longitude.optional(),
    association: z
      .object({
        name: z.string().trim().min(2).max(150),
        registration_number: z.string().trim().max(80).optional(),
        address: z.string().trim().max(255).optional(),
      })
      .optional(),
  })
  .refine((data) => data.role !== 'association' || data.association, {
    message: 'Informations de l’association requises',
    path: ['association'],
  });

const loginSchema = z.object({ email, password: z.string().min(1) });

export function publicUser(row) {
  const { password_hash: _passwordHash, ...user } = row;
  return user;
}

export async function loadProfile(userId) {
  const [user] = await query('SELECT * FROM users WHERE id = ?', [userId]);
  const [association] = await query(
    'SELECT id, name, registration_number, address, status, review_reason, reviewed_at FROM associations WHERE user_id = ?',
    [userId],
  );
  return { ...publicUser(user), association: association ?? null };
}

authRouter.post('/register', async (req, res) => {
  const data = registerSchema.parse(req.body);
  const passwordHash = await bcrypt.hash(data.password, 10);

  const userId = await transaction(async (conn) => {
    const [result] = await conn.query(
      `INSERT INTO users (name, email, password_hash, role, phone, latitude, longitude)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        data.name,
        data.email,
        passwordHash,
        data.role,
        data.phone ?? null,
        data.latitude ?? null,
        data.longitude ?? null,
      ],
    );

    if (data.role === 'association') {
      await conn.query(
        'INSERT INTO associations (user_id, name, registration_number, address) VALUES (?, ?, ?, ?)',
        [
          result.insertId,
          data.association.name,
          data.association.registration_number ?? null,
          data.association.address ?? null,
        ],
      );
    }
    return result.insertId;
  });

  const user = await loadProfile(userId);
  res.status(201).json({ token: signToken(user), user });
});

authRouter.post('/login', async (req, res) => {
  const data = loginSchema.parse(req.body);
  const [row] = await query('SELECT * FROM users WHERE email = ?', [data.email]);

  if (!row || !(await bcrypt.compare(data.password, row.password_hash))) {
    throw new HttpError(401, 'Email ou mot de passe incorrect');
  }
  if (row.status !== 'active') {
    throw new HttpError(403, 'Compte suspendu', { reason: row.status_reason });
  }

  const user = await loadProfile(row.id);
  res.json({ token: signToken(user), user });
});

authRouter.get('/me', authenticate, async (req, res) => {
  res.json(await loadProfile(req.user.id));
});
