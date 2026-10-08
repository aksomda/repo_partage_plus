import dotenv from 'dotenv';

dotenv.config({ quiet: true });

const env = process.env;
const isProduction = env.NODE_ENV === 'production';

/** Longueur minimale du secret JWT en production (signe aussi les codes OTP). */
const MIN_SECRET_LENGTH = 32;

if (
  isProduction &&
  (!env.JWT_SECRET || env.JWT_SECRET === 'change-moi' || env.JWT_SECRET.length < MIN_SECRET_LENGTH)
) {
  throw new Error(
    `JWT_SECRET doit être défini en production (${MIN_SECRET_LENGTH} caractères aléatoires minimum)`,
  );
}

if (isProduction && env.CORS_ORIGINS === '*') {
  console.warn('CORS_ORIGINS=* en production : limitez-le aux origines de l’application web');
}

/**
 * Proxys de confiance pour lire l'adresse IP du client (X-Forwarded-For) :
 * un seul (Render…) en production ; aucun sinon, pour qu'un client ne puisse
 * pas usurper son adresse et échapper aux limites de débit.
 */
function trustProxy(value) {
  if (value === undefined || value === '') return isProduction ? 1 : false;
  if (value === 'true') return true;
  if (value === 'false') return false;
  return /^\d+$/.test(value) ? Number(value) : value;
}

export const config = {
  isProduction,
  port: Number(env.PORT || 3000),
  trustProxy: trustProxy(env.TRUST_PROXY),
  // Limites de débit par adresse IP ; coupées pendant les tests automatiques.
  rateLimit: {
    enabled: env.RATE_LIMIT !== 'off' && env.NODE_ENV !== 'test',
    // Requêtes par minute, toutes routes de l'API confondues.
    perMinute: Number(env.RATE_LIMIT_PER_MINUTE || 300),
    // Inscription, codes et mot de passe oublié, par quart d'heure.
    authPer15Minutes: Number(env.RATE_LIMIT_AUTH_PER_15_MINUTES || 30),
  },
  db: {
    url: env.DATABASE_URL || null,
    ssl: env.DB_SSL === 'true',
    host: env.DB_HOST || '127.0.0.1',
    port: Number(env.DB_PORT || 3306),
    user: env.DB_USER || 'root',
    password: env.DB_PASSWORD || '',
    database: env.DB_NAME || 'repas_partage',
  },
  // MySQL d'un serveur distant joignable seulement par SSH : DB_HOST et
  // DB_PORT sont alors vus depuis ce serveur (en général 127.0.0.1:3306).
  sshTunnel: env.SSH_TUNNEL_HOST
    ? {
        host: env.SSH_TUNNEL_HOST,
        port: Number(env.SSH_TUNNEL_PORT || 22),
        user: env.SSH_TUNNEL_USER || 'ubuntu',
        key: env.SSH_TUNNEL_KEY || null,
        localPort: Number(env.SSH_TUNNEL_LOCAL_PORT || 13306),
      }
    : null,
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
  // Recherche à la voix (écran Recommandations) : IA ouverte via une API
  // compatible OpenAI. Groq par défaut (palier gratuit) ; Ollama ou un
  // serveur Whisper local en changeant l'adresse et les modèles.
  voiceAi: {
    apiKey: env.VOICE_AI_API_KEY || env.GROQ_API_KEY || null,
    baseUrl: (env.VOICE_AI_BASE_URL || 'https://api.groq.com/openai/v1').replace(/\/+$/, ''),
    sttModel: env.VOICE_AI_STT_MODEL || 'whisper-large-v3-turbo',
    llmModel: env.VOICE_AI_LLM_MODEL || 'openai/gpt-oss-120b',
    // Nom affiché dans l'application (« filtré par Groq »).
    label: env.VOICE_AI_LABEL || 'Groq',
  },
  // SMS des codes (activation, mot de passe oublié), en plus de l'e-mail.
  // SMS_PROVIDER vide : désactivé. 'android-gateway' : application « SMS
  // Gateway for Android » (sms-gate.app) sur un téléphone avec carte SIM.
  sms: {
    provider: env.SMS_PROVIDER || null,
    // Cloud par défaut ; en local (même Wi-Fi) : http://<ip-du-téléphone>:8080/message
    gatewayUrl: env.SMS_GATEWAY_URL || 'https://api.sms-gate.app/3rdparty/v1/messages',
    username: env.SMS_GATEWAY_USERNAME || null,
    password: env.SMS_GATEWAY_PASSWORD || null,
    // Plafond d'envois par jour, tous comptes confondus (forfait du téléphone).
    dailyLimit: Number(env.SMS_DAILY_LIMIT || 10),
    // Indicatif ajouté aux numéros saisis sans indicatif (Burkina Faso).
    defaultCountryCode: env.SMS_DEFAULT_COUNTRY_CODE || '+226',
  },
  otp: {
    ttlMinutes: Number(env.OTP_TTL_MINUTES || 10),
    maxAttempts: 5,
    resendDelaySeconds: 60,
    // Par compte et par usage, sur 24 h glissantes.
    maxCodesPerDay: 10,
    maxFailuresPerDay: 15,
  },
  seed: {
    lat: Number(env.SEED_LAT || 12.3714),
    lng: Number(env.SEED_LNG || -1.5197),
  },
};
