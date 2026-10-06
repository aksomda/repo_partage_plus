import { Router } from 'express';
import { z } from 'zod';

import { query, transaction } from '../db/pool.js';
import { authenticate } from '../http/auth.js';
import { HttpError, notFound } from '../http/errors.js';
import { id, idParam, pagination } from '../http/validation.js';
import { notify } from '../services/notifications.js';
import { decode, photoSchema } from '../services/photos.js';
import { MAX_MESSAGE_PHOTOS } from './messages.js';

/**
 * Messagerie entre utilisateurs avec compte : un bénéficiaire (particulier,
 * association…) écrit au publieur d'une offre (commerçant, restaurateur,
 * association, particulier), qui lui répond. L'administration a son propre
 * mini chat (routes /messages).
 */
export const directMessagesRouter = Router();

directMessagesRouter.use(authenticate);

export const DIRECT_MESSAGE_SELECT = `SELECT d.id, d.sender_id, d.recipient_id, d.offer_id,
    d.body, d.photos_count, d.read_at, d.created_at,
    s.name AS sender_name, sa.label AS sender_actor,
    r.name AS recipient_name, ra.label AS recipient_actor,
    o.title AS offer_title
  FROM direct_messages d
  JOIN users s ON s.id = d.sender_id
  JOIN users r ON r.id = d.recipient_id
  LEFT JOIN actors sa ON sa.id = s.actor_id
  LEFT JOIN actors ra ON ra.id = r.actor_id
  LEFT JOIN offers o ON o.id = d.offer_id`;

/** Messages copiés sur l'appareil (synchronisation). */
export const MAX_DIRECT_MESSAGES = 500;

/** Messages de [userId] (envoyés et reçus), les plus récents d'abord. */
export function loadDirectMessages(userId, limit = MAX_DIRECT_MESSAGES) {
  return query(
    `${DIRECT_MESSAGE_SELECT} WHERE d.sender_id = ? OR d.recipient_id = ?
     ORDER BY d.id DESC LIMIT ?`,
    [userId, userId, limit],
  );
}

const forbidden = () =>
  new HttpError(
    403,
    'Vous pouvez écrire au publieur d’une offre, à une personne qui a réservé ' +
      'votre offre, ou poursuivre une conversation déjà commencée',
  );

/**
 * Vérifie que [sender] peut écrire à [recipientId] : le destinataire publie
 * l'offre citée ; ou il a réservé une offre de l'expéditeur (ou l'inverse) ;
 * ou une conversation existe déjà entre eux. Jamais avec un administrateur
 * (il a son propre mini chat), ni avec soi-même.
 */
async function assertCanWrite(sender, recipientId, offerId) {
  if (sender.role === 'admin') throw forbidden();
  if (recipientId === sender.id) {
    throw new HttpError(400, 'Vous ne pouvez pas vous écrire à vous-même', {
      field: 'recipient_id',
    });
  }
  const [recipient] = await query('SELECT id, role, status FROM users WHERE id = ?', [
    recipientId,
  ]);
  if (!recipient || recipient.role === 'admin') throw notFound('Destinataire');
  if (recipient.status !== 'active') {
    throw new HttpError(409, 'Ce compte ne reçoit plus de messages');
  }

  if (offerId) {
    const [offer] = await query('SELECT donor_id FROM offers WHERE id = ?', [offerId]);
    if (!offer) throw notFound('Offre');
    if (offer.donor_id === recipientId) return;
    // Le publieur écrit à quelqu'un qui a réservé son offre.
    if (offer.donor_id === sender.id) {
      const [reserved] = await query(
        'SELECT 1 FROM reservations WHERE offer_id = ? AND beneficiary_id = ? LIMIT 1',
        [offerId, recipientId],
      );
      if (reserved) return;
    }
    throw forbidden();
  }

  const [linked] = await query(
    `SELECT 1 FROM direct_messages
       WHERE (sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)
     UNION ALL
     SELECT 1 FROM reservations r JOIN offers o ON o.id = r.offer_id
       WHERE (o.donor_id = ? AND r.beneficiary_id = ?) OR (o.donor_id = ? AND r.beneficiary_id = ?)
     LIMIT 1`,
    [
      sender.id,
      recipientId,
      recipientId,
      sender.id,
      sender.id,
      recipientId,
      recipientId,
      sender.id,
    ],
  );
  if (!linked) throw forbidden();
}

const listSchema = pagination.extend({ peer_id: id.optional() });

directMessagesRouter.get('/', async (req, res) => {
  const filters = listSchema.parse(req.query);
  const me = req.user.id;
  const rows = filters.peer_id
    ? await query(
        `${DIRECT_MESSAGE_SELECT}
         WHERE (d.sender_id = ? AND d.recipient_id = ?) OR (d.sender_id = ? AND d.recipient_id = ?)
         ORDER BY d.id DESC LIMIT ? OFFSET ?`,
        [me, filters.peer_id, filters.peer_id, me, filters.limit, filters.offset],
      )
    : await query(
        `${DIRECT_MESSAGE_SELECT} WHERE d.sender_id = ? OR d.recipient_id = ?
         ORDER BY d.id DESC LIMIT ? OFFSET ?`,
        [me, me, filters.limit, filters.offset],
      );
  res.json(rows);
});

const sendSchema = z
  .object({
    recipient_id: id,
    // Offre dont on parle (fiche détail) : ouvre la conversation.
    offer_id: id.optional().nullable(),
    body: z.string().trim().max(2000).optional().nullable(),
    photos: z
      .array(photoSchema.unwrap().unwrap())
      .max(MAX_MESSAGE_PHOTOS, `${MAX_MESSAGE_PHOTOS} images maximum`)
      .default([]),
  })
  .refine((data) => Boolean(data.body) || data.photos.length > 0, {
    message: 'Message vide : écrivez un texte ou joignez une image',
    path: ['body'],
  });

directMessagesRouter.post('/', async (req, res) => {
  const data = sendSchema.parse(req.body);
  await assertCanWrite(req.user, data.recipient_id, data.offer_id ?? null);
  // Images vérifiées (taille, vrai format) avant toute écriture.
  const photos = data.photos.map(decode);

  const messageId = await transaction(async (conn) => {
    const [result] = await conn.query(
      `INSERT INTO direct_messages (sender_id, recipient_id, offer_id, body, photos_count)
       VALUES (?, ?, ?, ?, ?)`,
      [req.user.id, data.recipient_id, data.offer_id ?? null, data.body || null, photos.length],
    );
    for (const [position, photo] of photos.entries()) {
      await conn.query(
        'INSERT INTO direct_message_photos (message_id, position, mime, data) VALUES (?, ?, ?, ?)',
        [result.insertId, position, photo.mime, photo.data],
      );
    }
    await notify(conn, data.recipient_id, {
      type: 'direct_message',
      title: `Message de ${req.user.name}`,
      body: data.body
        ? data.body.slice(0, 200)
        : `📷 ${photos.length} image${photos.length > 1 ? 's' : ''}`,
      data: {
        direct_message_id: result.insertId,
        peer_id: req.user.id,
        offer_id: data.offer_id ?? null,
      },
    });
    return result.insertId;
  });

  const [message] = await query(`${DIRECT_MESSAGE_SELECT} WHERE d.id = ?`, [messageId]);
  res.status(201).json(message);
});

/** Marque comme lus les messages reçus de [peer_id]. */
directMessagesRouter.patch('/read', async (req, res) => {
  const { peer_id: peerId } = z.object({ peer_id: id }).parse(req.body ?? {});
  await query(
    `UPDATE direct_messages SET read_at = NOW()
     WHERE recipient_id = ? AND sender_id = ? AND read_at IS NULL`,
    [req.user.id, peerId],
  );
  res.status(204).end();
});

const photoParams = idParam.extend({
  position: z.coerce.number().int().min(0).max(MAX_MESSAGE_PHOTOS - 1),
});

// Image d'un message : réservée à l'expéditeur et au destinataire.
directMessagesRouter.get('/:id/photos/:position', async (req, res) => {
  const { id: messageId, position } = photoParams.parse(req.params);
  const [photo] = await query(
    `SELECT d.sender_id, d.recipient_id, p.mime, p.data FROM direct_message_photos p
     JOIN direct_messages d ON d.id = p.message_id
     WHERE p.message_id = ? AND p.position = ?`,
    [messageId, position],
  );
  if (!photo || ![photo.sender_id, photo.recipient_id].includes(req.user.id)) {
    throw notFound('Image');
  }
  res
    .type(photo.mime)
    .set('Cache-Control', 'private, max-age=604800, immutable')
    .send(photo.data);
});
