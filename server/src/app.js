import { timingSafeEqual } from 'node:crypto';

import cors from 'cors';
import express from 'express';

import { config } from './config.js';
import { query } from './db/pool.js';
import { errorHandler, HttpError, notFoundHandler } from './http/errors.js';
import { idempotency } from './http/idempotency.js';
import { adminRouter } from './routes/admin.js';
import { aiRouter } from './routes/ai.js';
import { authRouter } from './routes/auth.js';
import { catalogRouter } from './routes/catalog.js';
import { impactRouter } from './routes/impact.js';
import { notificationsRouter } from './routes/notifications.js';
import { offersRouter } from './routes/offers.js';
import { recommendationsRouter } from './routes/recommendations.js';
import { reservationsRouter } from './routes/reservations.js';
import { syncRouter } from './routes/sync.js';
import { usersRouter } from './routes/users.js';
import { runScheduledJobs } from './services/jobs.js';

export const app = express();

app.set('trust proxy', 1);
app.use(cors({ origin: config.corsOrigins }));
app.use(express.json({ limit: '1mb' }));

// Utilisé par Render (health check) et pour réveiller le serveur avant la démo.
app.get('/health', async (req, res) => {
  await query('SELECT 1');
  res.json({ status: 'ok', time: new Date().toISOString() });
});

const api = express.Router();

api.use(idempotency);
api.use('/sync', syncRouter);
api.use('/auth', authRouter);
api.use('/users', usersRouter);
api.use('/offers', offersRouter);
api.use('/reservations', reservationsRouter);
api.use('/notifications', notificationsRouter);
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
