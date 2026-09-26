import { Router } from 'express';
import { z } from 'zod';

import { pool, query, transaction } from '../db/pool.js';
import { authenticate, requireRole } from '../http/auth.js';
import { HttpError, notFound } from '../http/errors.js';
import { id, idParam, pagination, reason } from '../http/validation.js';
import { runScheduledJobs } from '../services/jobs.js';
import { notify } from '../services/notifications.js';
import { OFFER_SELECT } from '../services/offers.js';

export const adminRouter = Router();

adminRouter.use(authenticate, requireRole('admin'));

const decisionSchema = z
  .object({ decision: z.enum(['approve', 'reject']), reason })
  .refine((data) => data.decision === 'approve' || data.reason, {
    message: 'Motif obligatoire en cas de refus',
    path: ['reason'],
  });

// ---------- Tableau de bord ----------

adminRouter.get('/stats', async (req, res) => {
  const [stats] = await query(`
    SELECT
      (SELECT COUNT(*) FROM offers WHERE status = 'pending') AS offers_pending,
      (SELECT COUNT(*) FROM offers WHERE status = 'published') AS offers_published,
      (SELECT COUNT(*) FROM associations WHERE status = 'pending') AS associations_pending,
      (SELECT COUNT(*) FROM users WHERE status = 'suspended') AS users_suspended,
      (SELECT COUNT(*) FROM users WHERE role <> 'admin') AS users_total,
      (SELECT COUNT(*) FROM reservations WHERE status = 'picked_up') AS pickups_total`);
  res.json(stats);
});

// ---------- Modération des offres ----------

const offerFilters = pagination.extend({
  status: z
    .enum(['pending', 'published', 'rejected', 'reserved', 'completed', 'expired', 'cancelled'])
    .default('pending'),
});

adminRouter.get('/offers', async (req, res) => {
  const filters = offerFilters.parse(req.query);
  const rows = await query(
    `${OFFER_SELECT} WHERE o.status = ? ORDER BY o.created_at ASC LIMIT ? OFFSET ?`,
    [filters.status, filters.limit, filters.offset],
  );
  res.json(rows);
});

adminRouter.patch('/offers/:id/moderation', async (req, res) => {
  const { id: offerId } = idParam.parse(req.params);
  const { decision, reason: motive } = decisionSchema.parse(req.body);

  await transaction(async (conn) => {
    const [[offer]] = await conn.query('SELECT * FROM offers WHERE id = ? FOR UPDATE', [
      offerId,
    ]);
    if (!offer) throw notFound('Offre');

    const allowed = decision === 'approve' ? ['pending'] : ['pending', 'published', 'reserved'];
    if (!allowed.includes(offer.status)) {
      throw new HttpError(409, `Décision impossible (statut : ${offer.status})`);
    }

    await conn.query(
      `UPDATE offers SET status = ?, moderation_reason = ?, moderated_by = ?, moderated_at = NOW()
       WHERE id = ?`,
      [decision === 'approve' ? 'published' : 'rejected', motive ?? null, req.user.id, offerId],
    );

    if (decision === 'reject') {
      // Une offre retirée après publication annule les réservations en cours.
      const [active] = await conn.query(
        `SELECT id, beneficiary_id FROM reservations
         WHERE offer_id = ? AND status IN ('pending', 'confirmed')`,
        [offerId],
      );
      await conn.query(
        `UPDATE reservations SET status = 'cancelled', cancelled_at = NOW()
         WHERE offer_id = ? AND status IN ('pending', 'confirmed')`,
        [offerId],
      );
      for (const reservation of active) {
        await notify(conn, reservation.beneficiary_id, {
          type: 'reservation_cancelled',
          title: 'Réservation annulée',
          body: `L’offre « ${offer.title} » a été retirée par la modération.`,
          data: { reservation_id: reservation.id, offer_id: offerId },
        });
      }
    }

    await notify(conn, offer.donor_id, {
      type: 'offer_moderated',
      title: decision === 'approve' ? 'Offre publiée' : 'Offre refusée',
      body:
        decision === 'approve'
          ? `« ${offer.title} » est maintenant visible.`
          : `« ${offer.title} » a été refusée : ${motive}`,
      data: { offer_id: offerId, decision },
    });
  });

  const [offer] = await query(`${OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  res.json(offer);
});

// ---------- Modération des comptes ----------

const userFilters = pagination.extend({
  role: z.enum(['donor', 'beneficiary', 'association', 'admin']).optional(),
  status: z.enum(['active', 'suspended']).optional(),
  q: z.string().trim().max(100).optional(),
});

adminRouter.get('/users', async (req, res) => {
  const filters = userFilters.parse(req.query);
  const where = ['1 = 1'];
  const params = [];

  if (filters.role) {
    where.push('role = ?');
    params.push(filters.role);
  }
  if (filters.status) {
    where.push('status = ?');
    params.push(filters.status);
  }
  if (filters.q) {
    where.push('(name LIKE ? OR email LIKE ?)');
    params.push(`%${filters.q}%`, `%${filters.q}%`);
  }

  const rows = await query(
    `SELECT id, name, email, role, phone, status, status_reason, created_at
     FROM users WHERE ${where.join(' AND ')}
     ORDER BY created_at DESC LIMIT ? OFFSET ?`,
    [...params, filters.limit, filters.offset],
  );
  res.json(rows);
});

const statusSchema = z
  .object({ status: z.enum(['active', 'suspended']), reason })
  .refine((data) => data.status === 'active' || data.reason, {
    message: 'Motif obligatoire pour une suspension',
    path: ['reason'],
  });

adminRouter.patch('/users/:id/status', async (req, res) => {
  const { id: userId } = idParam.parse(req.params);
  const data = statusSchema.parse(req.body);

  if (userId === req.user.id) {
    throw new HttpError(409, 'Impossible de modifier son propre compte');
  }

  const result = await query(
    'UPDATE users SET status = ?, status_reason = ? WHERE id = ? AND role <> ?',
    [data.status, data.status === 'active' ? null : data.reason, userId, 'admin'],
  );
  if (result.affectedRows === 0) throw notFound('Compte');

  await notify(pool, userId, {
    type: 'account_status',
    title: data.status === 'active' ? 'Compte réactivé' : 'Compte suspendu',
    body:
      data.status === 'active'
        ? 'Votre compte est de nouveau actif.'
        : `Votre compte a été suspendu : ${data.reason}`,
  });

  const [user] = await query(
    'SELECT id, name, email, role, status, status_reason FROM users WHERE id = ?',
    [userId],
  );
  res.json(user);
});

// ---------- Validation des associations ----------

const associationFilters = pagination.extend({
  status: z.enum(['pending', 'approved', 'rejected']).default('pending'),
});

adminRouter.get('/associations', async (req, res) => {
  const filters = associationFilters.parse(req.query);
  const rows = await query(
    `SELECT a.*, u.name AS user_name, u.email, u.phone
     FROM associations a JOIN users u ON u.id = a.user_id
     WHERE a.status = ? ORDER BY a.created_at ASC LIMIT ? OFFSET ?`,
    [filters.status, filters.limit, filters.offset],
  );
  res.json(rows);
});

adminRouter.patch('/associations/:id/review', async (req, res) => {
  const { id: associationId } = idParam.parse(req.params);
  const { decision, reason: motive } = decisionSchema.parse(req.body);

  const [association] = await query('SELECT * FROM associations WHERE id = ?', [
    associationId,
  ]);
  if (!association) throw notFound('Association');

  await query(
    `UPDATE associations SET status = ?, review_reason = ?, reviewed_by = ?, reviewed_at = NOW()
     WHERE id = ?`,
    [decision === 'approve' ? 'approved' : 'rejected', motive ?? null, req.user.id, associationId],
  );
  await notify(pool, association.user_id, {
    type: 'association_review',
    title: decision === 'approve' ? 'Association validée' : 'Association refusée',
    body:
      decision === 'approve'
        ? `« ${association.name} » est validée : vous pouvez réserver des offres.`
        : `« ${association.name} » n’a pas été validée : ${motive}`,
  });

  const [updated] = await query('SELECT * FROM associations WHERE id = ?', [associationId]);
  res.json(updated);
});

// ---------- Catégories ----------

const categorySchema = z.object({
  name: z.string().trim().min(2).max(80),
  icon: z.string().trim().max(50).nullable().optional(),
});

adminRouter.post('/categories', async (req, res) => {
  const data = categorySchema.parse(req.body);
  const result = await query('INSERT INTO categories (name, icon) VALUES (?, ?)', [
    data.name,
    data.icon ?? null,
  ]);
  const [category] = await query('SELECT * FROM categories WHERE id = ?', [result.insertId]);
  res.status(201).json(category);
});

adminRouter.put('/categories/:id', async (req, res) => {
  const { id: categoryId } = idParam.parse(req.params);
  const data = categorySchema.parse(req.body);
  const result = await query('UPDATE categories SET name = ?, icon = ? WHERE id = ?', [
    data.name,
    data.icon ?? null,
    categoryId,
  ]);
  if (result.affectedRows === 0) throw notFound('Catégorie');
  const [category] = await query('SELECT * FROM categories WHERE id = ?', [categoryId]);
  res.json(category);
});

adminRouter.delete('/categories/:id', async (req, res) => {
  const { id: categoryId } = idParam.parse(req.params);
  const result = await query('DELETE FROM categories WHERE id = ?', [categoryId]);
  if (result.affectedRows === 0) throw notFound('Catégorie');
  res.status(204).end();
});

// ---------- Facteurs d'impact ----------

const factorSchema = z.object({
  category_id: id,
  co2_kg_per_kg: z.coerce.number().min(0).max(1000),
  meals_per_kg: z.coerce.number().min(0).max(100).default(2.5),
  source: z.string().trim().max(255).nullable().optional(),
});

adminRouter.post('/factors', async (req, res) => {
  const data = factorSchema.parse(req.body);
  const result = await query(
    'INSERT INTO impact_factors (category_id, co2_kg_per_kg, meals_per_kg, source) VALUES (?, ?, ?, ?)',
    [data.category_id, data.co2_kg_per_kg, data.meals_per_kg, data.source ?? null],
  );
  const [factor] = await query('SELECT * FROM impact_factors WHERE id = ?', [result.insertId]);
  res.status(201).json(factor);
});

adminRouter.put('/factors/:id', async (req, res) => {
  const { id: factorId } = idParam.parse(req.params);
  const data = factorSchema.parse(req.body);
  const result = await query(
    `UPDATE impact_factors SET category_id = ?, co2_kg_per_kg = ?, meals_per_kg = ?, source = ?
     WHERE id = ?`,
    [data.category_id, data.co2_kg_per_kg, data.meals_per_kg, data.source ?? null, factorId],
  );
  if (result.affectedRows === 0) throw notFound('Facteur');
  const [factor] = await query('SELECT * FROM impact_factors WHERE id = ?', [factorId]);
  res.json(factor);
});

adminRouter.delete('/factors/:id', async (req, res) => {
  const { id: factorId } = idParam.parse(req.params);
  const result = await query('DELETE FROM impact_factors WHERE id = ?', [factorId]);
  if (result.affectedRows === 0) throw notFound('Facteur');
  res.status(204).end();
});

// ---------- Tâches planifiées ----------

adminRouter.post('/jobs/run', async (req, res) => {
  res.json(await runScheduledJobs());
});
