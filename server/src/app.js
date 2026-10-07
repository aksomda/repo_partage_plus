import { timingSafeEqual } from 'node:crypto';

import cors from 'cors';
import express from 'express';

import { config } from './config.js';
import { query } from './db/pool.js';
import { tokenUserId } from './http/auth.js';
import { errorHandler, HttpError, notFoundHandler } from './http/errors.js';
import { idempotency } from './http/idempotency.js';
import { rateLimit } from './http/rate_limit.js';
import { noStore, securityHeaders } from './http/security_headers.js';
import { adminRouter } from './routes/admin.js';
import { aiRouter } from './routes/ai.js';
import { authRouter } from './routes/auth.js';
import { catalogRouter } from './routes/catalog.js';
import { impactRouter } from './routes/impact.js';
import { directMessagesRouter } from './routes/direct_messages.js';
import { messagesRouter } from './routes/messages.js';
import { notificationsRouter } from './routes/notifications.js';
import { offersRouter } from './routes/offers.js';
import { recommendationsRouter } from './routes/recommendations.js';
import { reservationsRouter } from './routes/reservations.js';
import { syncRouter } from './routes/sync.js';
import { usersRouter } from './routes/users.js';
import { mirrorAfterWrite } from './services/firestore_mirror.js';
import { runScheduledJobs } from './services/jobs.js';

export const app = express();

app.disable('x-powered-by');
app.set('trust proxy', config.trustProxy);
app.use(securityHeaders);
app.use(cors({ origin: config.corsOrigins }));
// Marge pour la photo d'une offre (3 Mo, encodée en base64 : ~4 Mo) ; un
// message du mini chat peut joindre jusqu'à 3 images.
const jsonDefault = express.json({ limit: '5mb' });
const jsonMessages = express.json({ limit: '15mb' });
app.use((req, res, next) =>
  (req.path.startsWith('/api/messages') ? jsonMessages : jsonDefault)(req, res, next),
);

// Utilisé par Render (health check) et pour réveiller le serveur avant la démo.
app.get('/health', async (req, res) => {
  await query('SELECT 1');
  res.json({ status: 'ok', time: new Date().toISOString() });
});

const api = express.Router();

// Débit global, par compte (plusieurs utilisateurs derrière une même
// adresse IP d'opérateur mobile) ou par adresse IP sans compte : contre le
// déni de service et l'aspiration des données.
api.use(
  rateLimit({
    name: 'api',
    max: config.rateLimit.perMinute,
    windowMs: 60_000,
    key: (req) => {
      const userId = tokenUserId(req);
      return userId ? `user:${userId}` : `ip:${req.ip}`;
    },
  }),
);
// Routes qui envoient un e-mail ou un SMS, ou vérifient un code : limite
// stricte contre la recherche de codes et l'envoi massif de messages.
const authLimit = rateLimit({
  name: 'auth',
  max: config.rateLimit.authPer15Minutes,
  windowMs: 15 * 60_000,
});
for (const path of [
  '/auth/register',
  '/auth/verify-email',
  '/auth/resend-code',
  '/auth/password/forgot',
  '/auth/password/reset',
  '/auth/release-orphan',
]) {
  api.post(path, authLimit);
}
// Jetons et données personnelles : jamais gardés par un cache intermédiaire.
api.use(['/auth', '/users/me', '/sync', '/reservations', '/messages', '/direct-messages', '/notifications', '/admin'], noStore);

// Copie dans Firestore de tout ce qui a changé dans MySQL.
api.use(mirrorAfterWrite);
api.use(idempotency);
api.use('/sync', syncRouter);
api.use('/auth', authRouter);
api.use('/users', usersRouter);
api.use('/offers', offersRouter);
api.use('/reservations', reservationsRouter);
api.use('/notifications', notificationsRouter);
api.use('/messages', messagesRouter);
api.use('/direct-messages', directMessagesRouter);
api.use('/impact', impactRouter);
api.use('/recommendations', aiRouter);
api.use('/recommendations', recommendationsRouter);
api.use('/admin', adminRouter);
api.use('/', catalogRouter);

// Déclenchement des tâches par un cron externe (ex. cron-job.org).
api.post('/jobs/run', async (req, res) => {
  const expected = config.jobs.token;
  const given = req.get('x-jobs-token') ?? '';
  const valid =
    expected &&
    given.length === expected.length &&
    timingSafeEqual(Buffer.from(given), Buffer.from(expected));
  if (!valid) throw new HttpError(401, 'Jeton de tâche invalide');

  res.json(await runScheduledJobs());
});

app.use('/api', api);
app.use(notFoundHandler);
app.use(errorHandler);
