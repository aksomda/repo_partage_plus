import dotenv from 'dotenv';

dotenv.config({ quiet: true });

const env = process.env;
const isProduction = env.NODE_ENV === 'production';

if (isProduction && (!env.JWT_SECRET || env.JWT_SECRET === 'change-moi')) {
  throw new Error('JWT_SECRET doit être défini en production');
}

export const config = {
  isProduction,
  port: Number(env.PORT || 3000),
  db: {
    url: env.DATABASE_URL || null,
    ssl: env.DB_SSL === 'true',
    host: env.DB_HOST || '127.0.0.1',
    port: Number(env.DB_PORT || 3306),
    user: env.DB_USER || 'root',
    password: env.DB_PASSWORD || '',
    database: env.DB_NAME || 'repas_partage',
  },
  jwt: {
    secret: env.JWT_SECRET || 'dev-secret-a-ne-pas-utiliser-en-prod',
    expiresIn: env.JWT_EXPIRES_IN || '7d',
  },
  corsOrigins:
    !env.CORS_ORIGINS || env.CORS_ORIGINS === '*'
      ? '*'
      : env.CORS_ORIGINS.split(',').map((origin) => origin.trim()),
  jobs: {
    intervalMinutes: Number(env.JOBS_INTERVAL_MINUTES ?? 15),
    token: env.JOBS_TOKEN || null,
  },
  firebase: {
    projectId: env.FIREBASE_PROJECT_ID || null,
    // Contenu JSON du compte de service, brut ou encodé en base64.
    serviceAccount: env.FIREBASE_SERVICE_ACCOUNT || null,
  },
  // Copie des offres MySQL dans Firestore (MySQL reste la référence).
  // Active dès qu'un compte de service est fourni ; FIRESTORE_MIRROR=true
  // force l'activation (identifiants par défaut de Google Cloud).
  firestore: {
    enabled:
      env.FIRESTORE_MIRROR === 'true' ||
      (env.FIRESTORE_MIRROR !== 'false' && Boolean(env.FIREBASE_SERVICE_ACCOUNT)),
    databaseId: env.FIRESTORE_DATABASE_ID || '(default)',
  },
  smtp: {
    host: env.SMTP_HOST || null,
    port: Number(env.SMTP_PORT || 587),
    secure: env.SMTP_SECURE === 'true',
    user: env.SMTP_USER || null,
    password: env.SMTP_PASSWORD || null,
    from: env.MAIL_FROM || 'Partage+ <a.ksomda@gmail.com>',
  },
  // Envoi des e-mails : 'firebase' (extension Trigger Email, collection
  // Firestore) ou 'smtp'. Avec Firebase, SMTP sert de secours s'il est rempli.
  mail: {
    transport: env.MAIL_TRANSPORT === 'firebase' ? 'firebase' : 'smtp',
    collection: env.MAIL_COLLECTION || 'mail',
    // Sans MAIL_FROM, l'extension utilise son expéditeur par défaut.
    from: env.MAIL_FROM || null,
    // Adresse à laquelle arrivent les réponses des destinataires (les deux modes).
    replyTo: env.MAIL_REPLY_TO || null,
  },
  // IA de recommandation intégrée au serveur (repli de la Cloud Function).
  rodium: {
    apiKey: env.RODIUM_API_KEY || null,
    model: env.RODIUM_MODEL || 'openai/gpt-4o-mini',
    callsPerHour: Number(env.AI_CALLS_PER_HOUR || 30),
  },
  otp: {
    ttlMinutes: Number(env.OTP_TTL_MINUTES || 10),
    maxAttempts: 5,
    resendDelaySeconds: 60,
  },
  seed: {
    lat: Number(env.SEED_LAT || 12.3714),
    lng: Number(env.SEED_LNG || -1.5197),
  },
};
