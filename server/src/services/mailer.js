import nodemailer from 'nodemailer';

import { config } from '../config.js';

/** E-mails envoyés pendant les tests (aucun envoi réel). */
export const sentMails = [];

let transport = null;

function smtpTransport() {
  transport ??= nodemailer.createTransport({
    host: config.smtp.host,
    port: config.smtp.port,
    secure: config.smtp.secure,
    auth: config.smtp.user ? { user: config.smtp.user, pass: config.smtp.password } : undefined,
  });
  return transport;
}

/**
 * Envoie un e-mail. Sans SMTP configuré, hors production, le message est
 * affiché dans la console pour pouvoir tester l'inscription en local.
 */
export async function sendMail({ to, subject, text, html }) {
  if (process.env.NODE_ENV === 'test') {
    sentMails.push({ to, subject, text });
    return;
  }

  if (!config.smtp.host) {
    if (config.isProduction) throw new Error('SMTP_HOST non configuré');
    console.log(`\n[e-mail non envoyé : SMTP non configuré]\nÀ : ${to}\nObjet : ${subject}\n${text}\n`);
    return;
  }

  await smtpTransport().sendMail({ from: config.smtp.from, to, subject, text, html });
}
