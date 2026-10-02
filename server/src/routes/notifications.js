import { Router } from 'express';
import { z } from 'zod';

import { query } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { notFound } from '../http/errors.js';
import { idParam, pagination } from '../http/validation.js';

export const notificationsRouter = Router();

notificationsRouter.use(authenticate);

const listSchema = pagination.extend({
  unread: z.enum(['true', 'false']).optional(),
  // Permet à l'app de ne récupérer que les nouvelles notifications.
  after_id: z.coerce.number().int().min(0).optional(),
});

notificationsRouter.get('/', async (req, res) => {
  const filters = listSchema.parse(req.query);
  const where = ['user_id = ?'];
  const params = [req.user.id];

  if (filters.unread === 'true') where.push('read_at IS NULL');
  if (filters.after_id !== undefined) {
    where.push('id > ?');
    params.push(filters.after_id);
  }

  const rows = await query(
    `SELECT * FROM notifications WHERE ${where.join(' AND ')}
     ORDER BY id DESC LIMIT ? OFFSET ?`,
    [...params, filters.limit, filters.offset],
  );
  res.json(rows);
});

notificationsRouter.get('/unread-count', async (req, res) => {
  const [row] = await query(
    'SELECT COUNT(*) AS count FROM notifications WHERE user_id = ? AND read_at IS NULL',
    [req.user.id],
  );
  res.json(row);
});

notificationsRouter.patch('/read-all', async (req, res) => {
  await query(
    'UPDATE notifications SET read_at = NOW() WHERE user_id = ? AND read_at IS NULL',
    [req.user.id],
  );
  res.status(204).end();
});

notificationsRouter.patch('/:id/read', async (req, res) => {
  const { id } = idParam.parse(req.params);
  const result = await query(
    'UPDATE notifications SET read_at = COALESCE(read_at, NOW()) WHERE id = ? AND user_id = ?',
    [id, req.user.id],
  );
  if (result.affectedRows === 0) throw notFound('Notification');
  res.status(204).end();
});
