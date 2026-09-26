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
  seed: {
    lat: Number(env.SEED_LAT || 12.3714),
    lng: Number(env.SEED_LNG || -1.5197),
  },
};
