import { getFirestore } from 'firebase-admin/firestore';
import nodemailer from 'nodemailer';

import { config } from '../config.js';
import { HttpError } from '../http/errors.js';
import { firebaseApp } from './firebase.js';

/** E-mails envoyés pendant les tests (aucun envoi réel). */
export const sentMails = [];

let transport = null;

function smtpTransport() {
  transport ??= nodemailer.createTransport({
    host: config.smtp.host,
    port: config.smtp.port,
    // 465 : TLS dès la connexion ; 587 : STARTTLS rendu obligatoire, pour ne
    // jamais transmettre l'identifiant ni les codes en clair.
    secure: config.smtp.secure,
    requireTLS: !config.smtp.secure,
    tls: { minVersion: 'TLSv1.2', rejectUnauthorized: true },
    auth: config.smtp.user ? { user: config.smtp.user, pass: config.smtp.password } : undefined,
    connectionTimeout: 15_000,
  });
  return transport;
}

/**
 * Vérifie au démarrage la connexion et l'identification SMTP, pour signaler
 * tout de suite un mot de passe ou un hôte erroné (sans rien envoyer).
 */
export async function checkMailer() {
  if (config.mail.transport === 'firebase') {
    return `E-mails déposés dans Firestore (collection ${config.mail.collection}, extension Trigger Email)`;
  }
  if (!config.smtp.host) return 'E-mails non envoyés : renseignez SMTP_HOST dans .env (affichés dans la console)';
  try {
    await smtpTransport().verify();
    return `SMTP prêt (${config.smtp.host}:${config.smtp.port}, ${config.smtp.user ?? 'sans identifiant'})`;
  } catch (error) {
    return `SMTP en échec (${config.smtp.host}:${config.smtp.port}) : ${error.message}`;
  }
}

/**
 * Envoi par Firebase : le message est déposé dans la collection Firestore
 * surveillée par l'extension « Trigger Email from Firestore »
 * (firebase/firestore-send-email), qui l'envoie et note le résultat dans
 * le champ `delivery` du document.
 */
const realMailStore = {
  async add(document) {
    const app = firebaseApp();
    if (!app) throw new Error('Firebase non configuré (FIREBASE_PROJECT_ID)');
    const db = getFirestore(app, config.firestore.databaseId);
    await db.collection(config.mail.collection).add(document);
  },

  async purge(before) {
    const app = firebaseApp();
    if (!app) return 0;
    const db = getFirestore(app, config.firestore.databaseId);
    const old = await db
      .collection(config.mail.collection)
      .where('created_at', '<', before)
      .limit(500)
      .get();
    if (old.empty) return 0;
    const batch = db.batch();
    for (const doc of old.docs) batch.delete(doc.ref);
    await batch.commit();
    return old.size;
  },
};

let mailStore = realMailStore;

/** Durée de conservation des e-mails dans Firestore (ils contiennent les codes). */
const KEEP_MAILS_MS = 24 * 3_600_000;

async function sendWithFirebase({ to, subject, text, html }) {
  await mailStore.add({
    to,
    ...(config.mail.from ? { from: config.mail.from } : {}),
    message: { subject, text, ...(html ? { html } : {}) },
    created_at: new Date(),
  });
}

async function sendWithSmtp({ to, subject, text, html }) {
  try {
    await smtpTransport().sendMail({ from: config.smtp.from, to, subject, text, html });
  } catch (error) {
    // Identifiants refusés, serveur injoignable… : le détail reste dans la
    // console, l'application reçoit un message compréhensible.
    console.error(`SMTP : e-mail à ${to} non envoyé :`, error.message);
    throw new HttpError(503, 'L’e-mail n’a pas pu être envoyé : réessayez plus tard');
  }
}

/**
 * Envoie un e-mail : par Firebase si MAIL_TRANSPORT=firebase (SMTP en
 * secours si Firestore est injoignable), sinon par SMTP. Sans rien de
 * configuré, hors production, le message est affiché dans la console.
 */
export async function sendMail(mail) {
  if (process.env.NODE_ENV === 'test' && mailStore === realMailStore) {
    sentMails.push({ to: mail.to, subject: mail.subject, text: mail.text });
    return;
  }

  if (config.mail.transport === 'firebase') {
    try {
      await sendWithFirebase(mail);
      return;
    } catch (error) {
      if (!config.smtp.host) throw error;
      console.error('Firebase : e-mail non déposé, envoi par SMTP :', error.message);
    }
  }

  if (!config.smtp.host) {
    if (config.isProduction) throw new Error('Aucun envoi d’e-mail configuré (MAIL_TRANSPORT ou SMTP_HOST)');
    console.log(
      `\n[e-mail non envoyé : aucun envoi configuré]\nÀ : ${mail.to}\nObjet : ${mail.subject}\n${mail.text}\n`,
    );
    return;
  }

  await sendWithSmtp(mail);
}

/** Retire de Firestore les e-mails de plus de 24 h (tâches planifiées). */
export async function purgeFirebaseMails(now = new Date()) {
  if (config.mail.transport !== 'firebase') return 0;
  try {
    return await mailStore.purge(new Date(now.getTime() - KEEP_MAILS_MS));
  } catch (error) {
    console.error('Firebase : anciens e-mails non supprimés :', error.message);
    return 0;
  }
}

/** Pour les tests uniquement. `null` rétablit Firestore. */
export function setMailStore(fake) {
  mailStore = fake ?? realMailStore;
}
