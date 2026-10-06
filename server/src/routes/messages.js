import { Router } from 'express';
import { z } from 'zod';

import { query, transaction } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { HttpError, notFound } from '../http/errors.js';
import { id, idParam, pagination } from '../http/validation.js';
import { notify } from '../services/notifications.js';
import { decode, photoSchema } from '../services/photos.js';

/**
 * Mini chat entre chaque utilisateur et l'administration (comptes
 * uniquement : aucune route sans authentification). Une conversation par
 * utilisateur ; pièces jointes limitées aux images (JPEG, PNG, WebP).
 */
export const messagesRouter = Router();

messagesRouter.use(authenticate);

/** Nombre maximal d'images par message (corps JSON limité à 5 Mo). */
export const MAX_MESSAGE_PHOTOS = 3;

export const MESSAGE_SELECT = `SELECT m.id, m.user_id, m.sender_id, m.from_admin, m.body,
    m.photos_count, m.read_at, m.created_at, u.name AS user_name, s.name AS sender_name
  FROM messages m
  JOIN users u ON u.id = m.user_id
  JOIN users s ON s.id = m.sender_id`;

const isAdmin = (user) => user.role === 'admin';

/** Conversation visible par [user] : la sienne, ou n'importe laquelle pour un admin. */
function assertCanAccess(user, conversationUserId) {
  if (!isAdmin(user) && conversationUserId !== user.id) throw notFound('Conversation');
}

const listSchema = pagination.extend({
  user_id: id.optional(),
  after_id: z.coerce.number().int().min(0).optional(),
});

messagesRouter.get('/', async (req, res) => {
  const filters = listSchema.parse(req.query);
  const where = [];
  const params = [];
  if (!isAdmin(req.user)) {
    where.push('m.user_id = ?');
    params.push(req.user.id);
  } else if (filters.user_id) {
    where.push('m.user_id = ?');
    params.push(filters.user_id);
  }
  if (filters.after_id !== undefined) {
    where.push('m.id > ?');
    params.push(filters.after_id);
  }
  const rows = await query(
    `${MESSAGE_SELECT} ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY m.id DESC LIMIT ? OFFSET ?`,
    [...params, filters.limit, filters.offset],
  );
  res.json(rows);
});

const sendSchema = z
  .object({
    body: z.string().trim().max(2000).optional().nullable(),
    photos: z
      .array(photoSchema.unwrap().unwrap())
      .max(MAX_MESSAGE_PHOTOS, `${MAX_MESSAGE_PHOTOS} images maximum`)
      .default([]),
    // Administrateur : destinataire (conversation de cet utilisateur).
    user_id: id.optional(),
  })
  .refine((data) => Boolean(data.body) || data.photos.length > 0, {
    message: 'Message vide : écrivez un texte ou joignez une image',
    path: ['body'],
  });

messagesRouter.post('/', async (req, res) => {
  const data = sendSchema.parse(req.body);
  const fromAdmin = isAdmin(req.user);

  let conversationUserId = req.user.id;
  if (fromAdmin) {
    if (!data.user_id) throw new HttpError(400, 'Destinataire requis', { field: 'user_id' });
    const [target] = await query('SELECT id, role FROM users WHERE id = ?', [data.user_id]);
    if (!target || target.role === 'admin') throw notFound('Utilisateur');
    conversationUserId = target.id;
  }
  // Images vérifiées (taille, vrai format) avant toute écriture.
  const photos = data.photos.map(decode);

  const messageId = await transaction(async (conn) => {
    const [result] = await conn.query(
      `INSERT INTO messages (user_id, sender_id, from_admin, body, photos_count)
       VALUES (?, ?, ?, ?, ?)`,
      [conversationUserId, req.user.id, fromAdmin, data.body || null, photos.length],
    );
    for (const [position, photo] of photos.entries()) {
      await conn.query(
        'INSERT INTO message_photos (message_id, position, mime, data) VALUES (?, ?, ?, ?)',
        [result.insertId, position, photo.mime, photo.data],
      );
    }

    const preview = data.body
      ? data.body.slice(0, 200)
      : `📷 ${photos.length} image${photos.length > 1 ? 's' : ''}`;
    if (fromAdmin) {
      await notify(conn, conversationUserId, {
        type: 'message',
        title: 'Message de l’administration',
        body: preview,
        data: { message_id: result.insertId },
      });
    } else {
      const [admins] = await conn.query(
        "SELECT id FROM users WHERE role = 'admin' AND status = 'active'",
      );
      for (const admin of admins) {
        await notify(conn, admin.id, {
          type: 'message',
          title: `Message de ${req.user.name}`,
          body: preview,
          data: { message_id: result.insertId, user_id: req.user.id },
        });
      }
    }
    return result.insertId;
  });

  const [message] = await query(`${MESSAGE_SELECT} WHERE m.id = ?`, [messageId]);
  res.status(201).json(message);
});

/** Marque comme lus les messages reçus dans la conversation. */
messagesRouter.patch('/read', async (req, res) => {
  const data = z.object({ user_id: id.optional() }).parse(req.body ?? {});
  const fromAdmin = isAdmin(req.user);
  const conversationUserId = fromAdmin ? data.user_id : req.user.id;
  if (!conversationUserId) throw new HttpError(400, 'Conversation requise', { field: 'user_id' });

  // Lus : les messages de l'autre partie seulement.
  await query(
    `UPDATE messages SET read_at = NOW()
     WHERE user_id = ? AND from_admin = ? AND read_at IS NULL`,
    [conversationUserId, fromAdmin ? 0 : 1],
  );
  res.status(204).end();
});

const photoParams = idParam.extend({
  position: z.coerce.number().int().min(0).max(MAX_MESSAGE_PHOTOS - 1),
});

// Image d'un message : réservée aux participants de la conversation.
messagesRouter.get('/:id/photos/:position', async (req, res) => {
  const { id: messageId, position } = photoParams.parse(req.params);
  const [photo] = await query(
    `SELECT m.user_id, p.mime, p.data FROM message_photos p
     JOIN messages m ON m.id = p.message_id
     WHERE p.message_id = ? AND p.position = ?`,
    [messageId, position],
  );
  if (!photo) throw notFound('Image');
  assertCanAccess(req.user, photo.user_id);
  res
    .type(photo.mime)
    .set('Cache-Control', 'private, max-age=604800, immutable')
    .send(photo.data);
});
