import bcrypt from 'bcryptjs';
import { Router } from 'express';
import { z } from 'zod';

import { isDatabaseUnavailable, pool, query, transaction } from '../db/pool.js';
import { authenticate, requireRole } from '../http/auth.js';
import { HttpError, notFound } from '../http/errors.js';
import { id, idParam, pagination, reason } from '../http/validation.js';
import { firebase } from '../services/firebase.js';
import { markFirebaseSync } from '../services/firebase_sync.js';
import { firestoreMirror } from '../services/firestore_mirror.js';
import { runScheduledJobs } from '../services/jobs.js';
import { sendMail } from '../services/mailer.js';
import { notify } from '../services/notifications.js';
import { OFFER_SELECT } from '../services/offers.js';
import { loadSettings, saveSettings, settingsSchema } from '../services/settings.js';
import { BCRYPT_ROUNDS, email, password } from './auth.js';
import { buildGlobalImpact } from './impact.js';
import { forViewer, releaseQuantity, RESERVATION_SELECT } from './reservations.js';

export const adminRouter = Router();

adminRouter.use(authenticate, requireRole('admin'));

const decisionSchema = z
  .object({ decision: z.enum(['approve', 'reject']), reason })
  .refine((data) => data.decision === 'approve' || data.reason, {
    message: 'Motif obligatoire en cas de refus',
    path: ['reason'],
  });

// ---------- Tableau de bord ----------

/** Compteurs du tableau de bord et de la page Administration. */
export async function loadStats() {
  const [stats] = await query(`
    SELECT
      (SELECT COUNT(*) FROM offers WHERE status = 'pending') AS offers_pending,
      (SELECT COUNT(*) FROM offers WHERE status = 'published') AS offers_published,
      (SELECT COUNT(*) FROM users WHERE status = 'suspended') AS users_suspended,
      (SELECT COUNT(*) FROM users WHERE role <> 'admin') AS users_total,
      (SELECT COUNT(*) FROM reservations WHERE status = 'picked_up') AS pickups_total,
      (SELECT COUNT(*) FROM reservations WHERE status IN ('pending', 'confirmed')) AS reservations_open,
      (SELECT COUNT(*) FROM actors) AS actors_total,
      (SELECT COUNT(*) FROM categories) AS categories_total,
      (SELECT COUNT(*) FROM impact_factors) AS factors_total`);
  return Object.fromEntries(Object.entries(stats).map(([key, value]) => [key, Number(value)]));
}

adminRouter.get('/stats', async (req, res) => {
  res.json(await loadStats());
});

// ---------- Réservations (toute la plateforme, lecture seule) ----------

const reservationFilters = pagination.extend({
  status: z.enum(['pending', 'confirmed', 'picked_up', 'cancelled']).optional(),
});

adminRouter.get('/reservations', async (req, res) => {
  const filters = reservationFilters.parse(req.query);
  const rows = await query(
    `${RESERVATION_SELECT} ${filters.status ? 'WHERE r.status = ?' : ''}
     ORDER BY r.created_at DESC LIMIT ? OFFSET ?`,
    [...(filters.status ? [filters.status] : []), filters.limit, filters.offset],
  );
  // Le code de retrait reste réservé au bénéficiaire.
  res.json(rows.map((row) => forViewer(row, req.user)));
});

// ---------- Impact de la plateforme ----------

adminRouter.get('/impact', async (req, res) => {
  res.json(await buildGlobalImpact());
});

// ---------- Modération des offres ----------

const offerFilters = pagination.extend({
  status: z
    .enum(['pending', 'published', 'rejected', 'reserved', 'completed', 'expired', 'cancelled'])
    .default('published'),
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

  const withdrawn = await transaction(async (conn) => {
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
      title: decision === 'approve' ? 'Offre publiée' : 'Offre retirée',
      body:
        decision === 'approve'
          ? `« ${offer.title} » est maintenant visible.`
          : `« ${offer.title} » a été retirée par l’administrateur : ${motive}`,
      data: { offer_id: offerId, decision },
    });
    return decision === 'reject' ? offer : null;
  });

  // Avec ou sans compte : e-mail seulement si le publieur en a laissé un.
  if (withdrawn) await mailWithdrawal(withdrawn, motive);

  const [offer] = await query(`${OFFER_SELECT} WHERE o.id = ?`, [offerId]);
  res.json(offer);
});

async function mailWithdrawal(offer, motive) {
  const [contact] = await query('SELECT email FROM offer_contacts WHERE offer_id = ?', [offer.id]);
  if (!contact) return;
  try {
    await sendMail({
      to: contact.email,
      subject: `Partage+ : votre offre « ${offer.title} » a été retirée`,
      text:
        'Bonjour,\n\n' +
        `Votre offre « ${offer.title} » a été retirée par l’administrateur de Partage+.\n` +
        `Motif : ${motive}\n\n` +
        'Les réservations en cours ont été annulées.',
    });
  } catch (error) {
    // Le retrait est fait : un e-mail perdu ne doit pas l'annuler.
    console.error(`E-mail de retrait non envoyé à ${contact.email} :`, error.message);
  }
}

// ---------- Modération des comptes ----------

const userFilters = pagination.extend({
  role: z.enum(['donor', 'beneficiary', 'association', 'admin']).optional(),
  actor_id: id.optional(),
  status: z.enum(['pending', 'active', 'suspended']).optional(),
  q: z.string().trim().max(100).optional(),
});

export const USER_SELECT = `SELECT u.id, u.name, u.first_name, u.last_name, u.gender, u.age,
    u.email, u.role, u.actor_id, a.label AS actor_label, u.phone, u.status, u.status_reason,
    u.email_verified_at, u.created_at, u.updated_at
  FROM users u LEFT JOIN actors a ON a.id = u.actor_id`;

/** Mêmes filtres que la requête SQL, appliqués à la copie Firestore. */
function matchesFilters(user, filters) {
  const q = filters.q?.toLowerCase();
  return (
    (!filters.role || user.role === filters.role) &&
    (!filters.actor_id || Number(user.actor_id) === filters.actor_id) &&
    (!filters.status || user.status === filters.status) &&
    (!q || `${user.name ?? ''} ${user.email ?? ''}`.toLowerCase().includes(q))
  );
}

// MySQL indisponible : dernière copie des comptes dans Firestore
// (en-tête X-Data-Source: firestore), pour que l'écran reste utilisable.
adminRouter.get('/users', async (req, res) => {
  const filters = userFilters.parse(req.query);
  const where = ['1 = 1'];
  const params = [];

  if (filters.role) {
    where.push('u.role = ?');
    params.push(filters.role);
  }
  if (filters.actor_id) {
    where.push('u.actor_id = ?');
    params.push(filters.actor_id);
  }
  if (filters.status) {
    where.push('u.status = ?');
    params.push(filters.status);
  }
  if (filters.q) {
    where.push('(u.name LIKE ? OR u.email LIKE ?)');
    params.push(`%${filters.q}%`, `%${filters.q}%`);
  }

  try {
    const rows = await query(
      `${USER_SELECT} WHERE ${where.join(' AND ')}
       ORDER BY u.created_at DESC LIMIT ? OFFSET ?`,
      [...params, filters.limit, filters.offset],
    );
    res.set('X-Data-Source', 'mysql').json(rows);
  } catch (error) {
    if (!isDatabaseUnavailable(error)) throw error;
    const copy = await firestoreMirror.listUsers().catch(() => null);
    if (!copy) {
      throw new HttpError(503, 'Comptes momentanément indisponibles : réessayez plus tard');
    }
    const rows = copy
      .filter((user) => matchesFilters(user, filters))
      .slice(filters.offset, filters.offset + filters.limit);
    res.set('X-Data-Source', 'firestore').json(rows);
  }
});

/**
 * Compte créé par l'administrateur : actif d'emblée (pas de code par
 * e-mail), avec un mot de passe provisoire que l'utilisateur pourra changer
 * par « Mot de passe oublié ». Créé aussi dans Firebase si disponible.
 */
const createUserSchema = z.object({
  first_name: z.string().trim().min(2).max(80),
  last_name: z.string().trim().min(2).max(80),
  email,
  phone: z
    .string()
    .trim()
    .regex(/^\+?[0-9 ]{8,20}$/, 'Numéro de téléphone invalide')
    .nullable()
    .optional(),
  actor_id: id,
  password,
});

adminRouter.post('/users', async (req, res) => {
  const data = createUserSchema.parse(req.body);

  const [actor] = await query('SELECT * FROM actors WHERE id = ?', [data.actor_id]);
  if (!actor || !actor.active) throw new HttpError(400, 'Acteur inconnu ou désactivé');
  // Une association s'inscrit elle-même : ses informations sont à valider.
  if (actor.permission_role === 'association') {
    throw new HttpError(400, 'Une association s’inscrit elle-même depuis l’application');
  }

  const [taken] = await query('SELECT id FROM users WHERE email = ?', [data.email]);
  if (taken) {
    throw new HttpError(409, 'Un compte existe déjà avec cette adresse e-mail', {
      code: 'email_taken',
    });
  }

  const name = `${data.first_name} ${data.last_name}`;
  const firebaseUid = await firebase.createAccount({
    email: data.email,
    password: data.password,
    displayName: name,
  });

  let result;
  try {
    result = await query('INSERT INTO users SET ?', [
      {
        name,
        first_name: data.first_name,
        last_name: data.last_name,
        email: data.email,
        firebase_uid: firebaseUid,
        password_hash: await bcrypt.hash(data.password, BCRYPT_ROUNDS),
        role: actor.permission_role,
        actor_id: actor.id,
        phone: data.phone ?? null,
        status: 'active',
        email_verified_at: new Date(),
      },
    ]);
  } catch (error) {
    if (error.code !== 'ER_DUP_ENTRY') throw error;
    throw new HttpError(409, 'Un compte existe déjà avec cette adresse e-mail', {
      code: 'email_taken',
    });
  }

  // Firebase injoignable : compte recopié en arrière-plan.
  if (!firebaseUid) await markFirebaseSync(result.insertId);

  const [user] = await query(`${USER_SELECT} WHERE u.id = ?`, [result.insertId]);
  res.status(201).json(user);
});

/**
 * Compte désactivé : ses réservations en cours (comme bénéficiaire) et
 * celles faites sur ses offres (il ne pourrait plus les confirmer) sont
 * annulées, l'autre partie est prévenue. Ses offres sont masquées tant
 * qu'il est désactivé (voir DONOR_ACTIVE).
 */
async function cancelOpenReservations(conn, userId) {
  const [open] = await conn.query(
    `${RESERVATION_SELECT}
     WHERE (r.beneficiary_id = ? OR o.donor_id = ?) AND r.status IN ('pending', 'confirmed')
     FOR UPDATE`,
    [userId, userId],
  );
  for (const reservation of open) {
    await conn.query(
      "UPDATE reservations SET status = 'cancelled', cancelled_at = NOW() WHERE id = ?",
      [reservation.id],
    );
    await releaseQuantity(conn, reservation);
    const donorSuspended = reservation.donor_id === userId;
    await notify(conn, donorSuspended ? reservation.beneficiary_id : reservation.donor_id, {
      type: 'reservation_cancelled',
      title: 'Réservation annulée',
      body: donorSuspended
        ? `L’offre « ${reservation.offer_title} » n’est plus disponible : le compte du donateur a été désactivé.`
        : `La réservation de « ${reservation.offer_title} » a été annulée : le compte du bénéficiaire a été désactivé.`,
      data: { reservation_id: reservation.id, offer_id: reservation.offer_id },
    });
  }
}

const statusSchema = z
  .object({ status: z.enum(['active', 'suspended']), reason })
  .refine((data) => data.status === 'active' || data.reason, {
    message: 'Motif obligatoire pour une désactivation',
    path: ['reason'],
  });

adminRouter.patch('/users/:id/status', async (req, res) => {
  const { id: userId } = idParam.parse(req.params);
  const data = statusSchema.parse(req.body);

  if (userId === req.user.id) {
    throw new HttpError(409, 'Impossible de modifier son propre compte');
  }

  await transaction(async (conn) => {
    // Suspension : les jetons déjà délivrés ne resserviront pas après une
    // réactivation (token_version augmentée).
    const [result] = await conn.query(
      `UPDATE users SET status = ?, status_reason = ?,
         token_version = token_version + IF(? = 'suspended', 1, 0)
       WHERE id = ? AND role <> ?`,
      [data.status, data.status === 'active' ? null : data.reason, data.status, userId, 'admin'],
    );
    if (result.affectedRows === 0) throw notFound('Compte');
    if (data.status === 'suspended') await cancelOpenReservations(conn, userId);
  });

  // Désactivé aussi dans Firebase : plus aucune connexion possible.
  const [{ firebase_uid: firebaseUid }] = await query(
    'SELECT firebase_uid FROM users WHERE id = ?',
    [userId],
  );
  if (!(await firebase.syncDisabled(firebaseUid, data.status === 'suspended'))) {
    await markFirebaseSync(userId);
  }

  await notify(pool, userId, {
    type: 'account_status',
    title: data.status === 'active' ? 'Compte réactivé' : 'Compte désactivé',
    body:
      data.status === 'active'
        ? 'Votre compte est de nouveau actif.'
        : `Votre compte a été désactivé : ${data.reason}`,
  });

  const [user] = await query(
    'SELECT id, name, email, role, status, status_reason FROM users WHERE id = ?',
    [userId],
  );
  res.json(user);
});

// ---------- Acteurs (profils proposés à l'inscription) ----------

const actorSchema = z
  .object({
    code: z
      .string()
      .trim()
      .toLowerCase()
      .regex(/^[a-z0-9_-]{2,40}$/, 'Code : lettres minuscules, chiffres, - ou _'),
    label: z.string().trim().min(2).max(80),
    description: z.string().trim().max(255).nullable().optional(),
    icon: z.string().trim().max(50).nullable().optional(),
    permission_role: z.enum(['donor', 'beneficiary', 'association', 'admin']),
    self_signup: z.boolean().default(true),
    active: z.boolean().default(true),
    sort_order: z.coerce.number().int().min(0).max(999).default(0),
  })
  // Personne ne doit pouvoir s'inscrire lui-même administrateur.
  .refine((data) => data.permission_role !== 'admin' || !data.self_signup, {
    message: 'Un acteur administrateur ne peut pas être proposé à l’inscription',
    path: ['self_signup'],
  });

const ACTOR_SELECT = `SELECT a.*, (SELECT COUNT(*) FROM users u WHERE u.actor_id = a.id) AS users_count
  FROM actors a`;

function actorValues(data) {
  return {
    code: data.code,
    label: data.label,
    description: data.description ?? null,
    icon: data.icon ?? null,
    permission_role: data.permission_role,
    self_signup: data.self_signup,
    active: data.active,
    sort_order: data.sort_order,
  };
}

adminRouter.get('/actors', async (req, res) => {
  res.json(await query(`${ACTOR_SELECT} ORDER BY a.sort_order, a.label`));
});

adminRouter.post('/actors', async (req, res) => {
  const data = actorSchema.parse(req.body);
  const result = await query('INSERT INTO actors SET ?', [actorValues(data)]);
  const [actor] = await query(`${ACTOR_SELECT} WHERE a.id = ?`, [result.insertId]);
  res.status(201).json(actor);
});

adminRouter.put('/actors/:id', async (req, res) => {
  const { id: actorId } = idParam.parse(req.params);
  const data = actorSchema.parse(req.body);

  const [current] = await query(`${ACTOR_SELECT} WHERE a.id = ?`, [actorId]);
  if (!current) throw notFound('Acteur');
  // Changer les droits d'un acteur utilisé changerait ceux de tous ses comptes.
  if (current.permission_role !== data.permission_role && current.users_count > 0) {
    throw new HttpError(
      409,
      `Droits non modifiables : ${current.users_count} compte(s) utilisent cet acteur`,
    );
  }

  await query('UPDATE actors SET ? WHERE id = ?', [actorValues(data), actorId]);
  const [actor] = await query(`${ACTOR_SELECT} WHERE a.id = ?`, [actorId]);
  res.json(actor);
});

adminRouter.delete('/actors/:id', async (req, res) => {
  const { id: actorId } = idParam.parse(req.params);
  // Refusé (409) si des comptes l'utilisent : le désactiver à la place.
  const result = await query('DELETE FROM actors WHERE id = ?', [actorId]);
  firestoreMirror.deleted('actors', [actorId]);
  if (result.affectedRows === 0) throw notFound('Acteur');
  res.status(204).end();
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
  firestoreMirror.deleted('categories', [categoryId]);
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
  firestoreMirror.deleted('impact_factors', [factorId]);
  if (result.affectedRows === 0) throw notFound('Facteur');
  res.status(204).end();
});

// ---------- Paramètres ----------

adminRouter.get('/settings', async (req, res) => {
  res.json(await loadSettings());
});

adminRouter.put('/settings', async (req, res) => {
  res.json(await saveSettings(settingsSchema.parse(req.body)));
});

// ---------- Tâches planifiées ----------

adminRouter.post('/jobs/run', async (req, res) => {
  res.json(await runScheduledJobs());
});
