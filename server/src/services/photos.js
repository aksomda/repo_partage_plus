import { z } from 'zod';

import { query } from '../db/pool.js';
import { HttpError } from '../http/errors.js';

/** Taille maximale d'une photo, une fois décodée (l'application la réduit avant envoi). */
export const MAX_PHOTO_BYTES = 3 * 1024 * 1024;

/** Signature des formats acceptés (premiers octets du fichier). */
const SIGNATURES = {
  'image/jpeg': (bytes) => bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff,
  'image/png': (bytes) => bytes.subarray(0, 4).toString('hex') === '89504e47',
  'image/webp': (bytes) =>
    bytes.subarray(0, 4).toString('ascii') === 'RIFF' &&
    bytes.subarray(8, 12).toString('ascii') === 'WEBP',
};

/**
 * Photo envoyée dans le JSON de l'offre : `data:image/jpeg;base64,…`.
 * `null` retire la photo, absente : inchangée.
 */
export const photoSchema = z
  .string()
  .max(Math.ceil((MAX_PHOTO_BYTES * 4) / 3) + 40, 'Photo trop lourde (3 Mo maximum)')
  .regex(/^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$/, 'Photo invalide : JPEG, PNG ou WebP')
  .nullable()
  .optional();

export function decode(dataUrl) {
  const [header, base64] = dataUrl.split(',');
  const mime = header.slice('data:'.length, header.indexOf(';'));
  const data = Buffer.from(base64, 'base64');
  if (data.length > MAX_PHOTO_BYTES) {
    throw new HttpError(400, 'Photo trop lourde (3 Mo maximum)', { field: 'photo' });
  }
  if (!SIGNATURES[mime]?.(data)) {
    throw new HttpError(400, 'Photo invalide : JPEG, PNG ou WebP', { field: 'photo' });
  }
  return { mime, data };
}

/** Enregistre, remplace ou retire la photo de profil du compte. */
export async function saveUserPhoto(userId, photo) {
  if (photo === null) {
    await query('DELETE FROM user_photos WHERE user_id = ?', [userId]);
    await query('UPDATE users SET photo_updated_at = NULL WHERE id = ?', [userId]);
    return;
  }
  const { mime, data } = decode(photo);
  await query(
    `INSERT INTO user_photos (user_id, mime, data) VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE mime = VALUES(mime), data = VALUES(data)`,
    [userId, mime, data],
  );
  await query('UPDATE users SET photo_updated_at = NOW() WHERE id = ?', [userId]);
}

/** Enregistre, remplace ou retire la photo de l'offre (dans la transaction). */
export async function savePhoto(conn, offerId, photo) {
  if (photo === undefined) return;
  if (photo === null) {
    await conn.query('DELETE FROM offer_photos WHERE offer_id = ?', [offerId]);
    await conn.query('UPDATE offers SET photo_updated_at = NULL WHERE id = ?', [offerId]);
    return;
  }
  const { mime, data } = decode(photo);
  await conn.query(
    `INSERT INTO offer_photos (offer_id, mime, data) VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE mime = VALUES(mime), data = VALUES(data)`,
    [offerId, mime, data],
  );
  await conn.query('UPDATE offers SET photo_updated_at = NOW() WHERE id = ?', [offerId]);
}
