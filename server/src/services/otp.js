import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';

import { config } from '../config.js';
import { HttpError } from '../http/errors.js';
import { sendMail } from './mailer.js';

/** Le code n'est jamais stocké en clair : seul son HMAC l'est. */
function hashCode(userId, code) {
  return createHmac('sha256', config.jwt.secret).update(`${userId}:${code}`).digest('hex');
}

/** Texte de l'e-mail selon l'usage du code. */
const PURPOSES = {
  activation: {
    subject: 'votre code d’activation',
    label: 'Votre code d’activation Partage+ est',
    ignore: 'Si vous n’êtes pas à l’origine de cette inscription, ignorez ce message.',
  },
  password_reset: {
    subject: 'réinitialisation de votre mot de passe',
    label: 'Votre code pour choisir un nouveau mot de passe Partage+ est',
    ignore: 'Si vous n’avez rien demandé, ignorez ce message : votre mot de passe reste inchangé.',
  },
};

/** Code d'activation du compte, envoyé après l'inscription. */
export const issueActivationCode = (conn, user) => issueCode(conn, user, 'activation');
export const consumeActivationCode = (conn, userId, code) =>
  consumeCode(conn, userId, code, 'activation');

/**
 * Crée un nouveau code (les précédents du même usage deviennent
 * inutilisables) et l'envoie par e-mail.
 */
export async function issueCode(conn, user, purpose) {
  const wording = PURPOSES[purpose];
  const [[last]] = await conn.query(
    `SELECT TIMESTAMPDIFF(SECOND, created_at, NOW()) AS age FROM email_otps
     WHERE user_id = ? AND purpose = ? ORDER BY id DESC LIMIT 1`,
    [user.id, purpose],
  );
  if (last && last.age < config.otp.resendDelaySeconds) {
    const wait = config.otp.resendDelaySeconds - last.age;
    throw new HttpError(429, `Patientez ${wait} s avant de demander un nouveau code`);
  }

  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
  await conn.query(
    'UPDATE email_otps SET consumed_at = NOW() WHERE user_id = ? AND purpose = ? AND consumed_at IS NULL',
    [user.id, purpose],
  );
  await conn.query(
    `INSERT INTO email_otps (user_id, purpose, code_hash, expires_at)
     VALUES (?, ?, ?, NOW() + INTERVAL ? MINUTE)`,
    [user.id, purpose, hashCode(user.id, code), config.otp.ttlMinutes],
  );

  await sendMail({
    to: user.email,
    subject: `Partage+ : ${wording.subject} (${code})`,
    text:
      `Bonjour ${user.first_name ?? user.name},\n\n` +
      `${wording.label} : ${code}\n` +
      `Il est valable ${config.otp.ttlMinutes} minutes.\n\n` +
      wording.ignore,
    html:
      `<p>Bonjour ${escapeHtml(user.first_name ?? user.name)},</p>` +
      `<p>${wording.label} :</p>` +
      `<p style="font-size:28px;font-weight:bold;letter-spacing:6px;color:#1B7A3A">${code}</p>` +
      `<p>Il est valable ${config.otp.ttlMinutes} minutes.</p>` +
      `<p style="color:#6B7A70">${wording.ignore}</p>`,
  });
}

/** Vérifie le code ; lève une erreur explicite sinon. */
export async function consumeCode(conn, userId, code, purpose) {
  const [[otp]] = await conn.query(
    `SELECT id, code_hash, attempts, expires_at < NOW() AS expired FROM email_otps
     WHERE user_id = ? AND purpose = ? AND consumed_at IS NULL ORDER BY id DESC LIMIT 1 FOR UPDATE`,
    [userId, purpose],
  );
  if (!otp || otp.expired) {
    throw new HttpError(400, 'Code expiré : demandez un nouveau code', { code: 'otp_expired' });
  }
  if (otp.attempts >= config.otp.maxAttempts) {
    throw new HttpError(429, 'Trop d’essais : demandez un nouveau code', { code: 'otp_locked' });
  }

  const expected = Buffer.from(otp.code_hash, 'hex');
  const given = Buffer.from(hashCode(userId, code), 'hex');
  if (!timingSafeEqual(expected, given)) {
    await conn.query('UPDATE email_otps SET attempts = attempts + 1 WHERE id = ?', [otp.id]);
    const left = config.otp.maxAttempts - otp.attempts - 1;
    throw new HttpError(400, `Code incorrect (${left} essai(s) restant(s))`, {
      code: 'otp_invalid',
    });
  }

  await conn.query('UPDATE email_otps SET consumed_at = NOW() WHERE id = ?', [otp.id]);
}

function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char],
  );
}
