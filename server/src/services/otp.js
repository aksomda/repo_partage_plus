import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';

import { config } from '../config.js';
import { HttpError } from '../http/errors.js';
import { sendMail } from './mailer.js';
import { sendPush } from './push.js';
import { sendSms } from './sms.js';

/** Le code n'est jamais stocké en clair : seul son HMAC l'est. */
function hashCode(userId, code) {
  return createHmac('sha256', config.jwt.secret).update(`${userId}:${code}`).digest('hex');
}

/** Texte de l'e-mail selon l'usage du code. */
const PURPOSES = {
  activation: {
    subject: 'votre code d’activation',
    title: 'Code d’activation',
    label: 'Votre code d’activation Partage+ est',
    ignore: 'Si vous n’êtes pas à l’origine de cette inscription, ignorez ce message.',
  },
  password_reset: {
    subject: 'réinitialisation de votre mot de passe',
    title: 'Mot de passe oublié',
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
 * inutilisables) et l'envoie par e-mail (canal principal : un échec annule
 * tout). En complément, SMS et push partent une fois la transaction
 * validée (voir sendCodeExtras).
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
  // Plafond du jour : contre l'envoi massif d'e-mails et de SMS à un compte.
  const [[{ issued }]] = await conn.query(
    `SELECT COUNT(*) AS issued FROM email_otps
     WHERE user_id = ? AND purpose = ? AND created_at > NOW() - INTERVAL 1 DAY`,
    [user.id, purpose],
  );
  if (issued >= config.otp.maxCodesPerDay) {
    throw new HttpError(429, 'Trop de codes demandés aujourd’hui : réessayez demain', {
      code: 'otp_daily_limit',
    });
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
  conn.afterCommit.push(() => sendInBackground(sendCodeExtras(user, purpose, code)));
}

const background = new Set();

/** Envoi en arrière-plan : une passerelle SMS lente ne retarde pas la réponse. */
function sendInBackground(promise) {
  const tracked = promise.catch((error) => console.error('Code non envoyé :', error.message));
  background.add(tracked);
  tracked.finally(() => background.delete(tracked));
}

/** Pour les tests : attend la fin des envois en arrière-plan. */
export async function flushCodeExtras() {
  await Promise.all(background);
}

/**
 * Compléments de l'e-mail, sans jamais faire échouer la demande :
 * - SMS au numéro du compte (si SMS_PROVIDER est renseigné, dans le plafond
 *   du jour) ;
 * - push aux appareils du compte : ceux déjà connectés pour le mot de passe
 *   oublié, celui de l'inscription pour l'activation. Jamais à l'appareil qui
 *   fait la demande : sinon n'importe qui recevrait le code d'un autre compte.
 */
async function sendCodeExtras(user, purpose, code) {
  const wording = PURPOSES[purpose];
  const minutes = config.otp.ttlMinutes;
  await Promise.all([
    user.phone
      ? sendSms(
          user.phone,
          // Sans apostrophe typographique : un seul SMS (alphabet GSM, 160 caractères).
          `Partage+ - ${wording.title.replace('’', "'")} : ${code}. Valable ${minutes} min. Ne le communiquez à personne.`,
        )
      : null,
    sendPush(
      user.id,
      {
        type: 'otp_code',
        title: `${wording.title} : ${code}`,
        body: `Valable ${minutes} minutes. Ne le communiquez à personne.`,
        data: { purpose, code },
      },
      { always: true },
    ),
  ]);
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
  // Essais ratés sur 24 h, tous codes confondus : demander sans cesse un
  // nouveau code ne permet pas d'essayer indéfiniment.
  const [[{ failures }]] = await conn.query(
    `SELECT COALESCE(SUM(attempts), 0) AS failures FROM email_otps
     WHERE user_id = ? AND purpose = ? AND created_at > NOW() - INTERVAL 1 DAY`,
    [userId, purpose],
  );
  if (Number(failures) >= config.otp.maxFailuresPerDay) {
    throw new HttpError(429, 'Trop d’essais aujourd’hui : réessayez demain', {
      code: 'otp_daily_locked',
    });
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
