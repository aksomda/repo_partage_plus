import { getFirestore } from 'firebase-admin/firestore';

import { config } from '../config.js';
import { query } from '../db/pool.js';
import { firebaseApp } from './firebase.js';

/**
 * Copie de la base MySQL (repas_partage) dans Firestore : une collection par
 * table, un document par ligne, identifiant = id MySQL, mêmes colonnes.
 *
 * MySQL reste la référence. Après chaque requête qui modifie des données,
 * les lignes dont `updated_at` a changé sont recopiées, toutes tables
 * confondues : aucune route ne peut être oubliée. Un échec est journalisé et
 * rattrapé au passage suivant (la date du dernier passage réussi est gardée
 * dans Firestore, document `_mirror/state`).
 */

/**
 * Tables copiées, avec les colonnes à ne jamais sortir de MySQL.
 * Non copiées : email_otps, guest_tokens (secrets), idempotency_keys
 * (technique), offer_photos, message_photos et direct_message_photos (images
 * trop lourdes pour Firestore).
 */
export const MIRRORED_TABLES = {
  actors: {},
  users: { omit: ['password_hash'] },
  associations: {},
  categories: {},
  impact_factors: {},
  offers: {},
  reservations: {},
  notifications: {},
  messages: {},
  direct_messages: {},
};

/**
 * Recouvrement entre deux passages : une transaction lente peut être validée
 * après le passage suivant avec un `updated_at` antérieur. Recopier quelques
 * lignes deux fois est sans effet.
 */
const OVERLAP_MS = 2 * 60_000;

/** Taille maximale d'un lot d'écritures Firestore. */
const BATCH_SIZE = 500;

const STATE = { collection: '_mirror', doc: 'state' };

/** Tableaux de bord d'impact calculés, copie de secours (hors tables MySQL). */
const DASHBOARDS = 'impact_dashboards';

function firestore() {
  const app = firebaseApp();
  if (!app) throw new Error('Firebase non configuré (FIREBASE_PROJECT_ID)');
  return getFirestore(app, config.firestore.databaseId);
}

async function inBatches(items, apply) {
  const db = firestore();
  for (let start = 0; start < items.length; start += BATCH_SIZE) {
    const batch = db.batch();
    for (const item of items.slice(start, start + BATCH_SIZE)) apply(db, batch, item);
    await batch.commit();
  }
}

const realStore = {
  async write(collection, rows) {
    await inBatches(rows, (db, batch, row) =>
      batch.set(db.collection(collection).doc(String(row.id)), row),
    );
  },
  async remove(collection, ids) {
    await inBatches(ids, (db, batch, id) => batch.delete(db.collection(collection).doc(String(id))));
  },
  async listIds(collection) {
    const refs = await firestore().collection(collection).listDocuments();
    return refs.map((ref) => ref.id);
  },
  async readDoc(collection, id) {
    const snap = await firestore().collection(collection).doc(String(id)).get();
    return snap.exists ? snap.data() : null;
  },
  async readAll(collection) {
    const snap = await firestore().collection(collection).get();
    return snap.docs.map((doc) => doc.data());
  },
  async readState() {
    const snap = await firestore().collection(STATE.collection).doc(STATE.doc).get();
    return snap.exists ? (snap.get('last_sync')?.toDate?.() ?? null) : null;
  },
  async writeState(lastSync) {
    await firestore().collection(STATE.collection).doc(STATE.doc).set({ last_sync: lastSync });
  },
};

let store = realStore;
let enabled = config.firestore.enabled;
/** Date (horloge MySQL) du dernier passage réussi ; undefined : pas encore lue. */
let lastSync;
let queue = Promise.resolve();
let pending = false;

/** Dates Firestore (Timestamp) relues en chaînes ISO, comme celles de MySQL. */
function plainDates(doc) {
  const out = {};
  for (const [key, value] of Object.entries(doc)) {
    out[key] = typeof value?.toDate === 'function' ? value.toDate().toISOString() : value;
  }
  return out;
}

function withoutSecrets(table, rows) {
  const { omit = [] } = MIRRORED_TABLES[table];
  if (omit.length === 0) return rows;
  return rows.map((row) => {
    const copy = { ...row };
    for (const column of omit) delete copy[column];
    return copy;
  });
}

/** Copie les lignes modifiées depuis [since] (null : tout). Renvoie le nombre par table. */
async function copyChanged(since) {
  const [{ now }] = await query('SELECT NOW() AS now');
  const counts = {};
  // Lectures en parallèle (un aller-retour au lieu d'un par table), écritures
  // Firestore ensuite, une table après l'autre.
  const tables = Object.keys(MIRRORED_TABLES);
  const changed = await Promise.all(
    tables.map((table) =>
      since
        ? query(`SELECT * FROM ${table} WHERE updated_at >= ?`, [since])
        : query(`SELECT * FROM ${table}`),
    ),
  );
  for (const [index, table] of tables.entries()) {
    const rows = changed[index];
    if (rows.length > 0) await store.write(table, withoutSecrets(table, rows));
    counts[table] = rows.length;
  }
  return { now, counts };
}

async function syncChanged() {
  if (lastSync === undefined) lastSync = await store.readState();
  const since = lastSync ? new Date(lastSync.getTime() - OVERLAP_MS) : null;
  const { now } = await copyChanged(since);
  await store.writeState(now);
  lastSync = now;
}

/** Les passages s'enchaînent : un seul à la fois, et un de plus si on l'a demandé entre-temps. */
function schedule() {
  if (pending) return;
  pending = true;
  queue = queue
    .then(() => {
      pending = false;
      return syncChanged();
    })
    .catch((error) => console.error('Firestore : copie MySQL non faite :', error.message));
}

export const firestoreMirror = {
  get enabled() {
    return enabled;
  },

  /** Des données ont changé dans MySQL : recopie en arrière-plan. */
  changed() {
    if (enabled) schedule();
  },

  /** Lignes supprimées de MySQL : retirées de Firestore en arrière-plan. */
  deleted(table, ids) {
    if (!enabled || ids.length === 0) return;
    queue = queue
      .then(() => store.remove(table, ids))
      .catch((error) => console.error('Firestore : suppression non faite :', error.message));
  },

  /**
   * Garde une copie du tableau de bord d'impact calculé (collection
   * impact_dashboards, id = id de l'utilisateur), en arrière-plan.
   */
  saveDashboard(userId, dashboard) {
    if (!enabled) return;
    queue = queue
      .then(() => store.write(DASHBOARDS, [{ id: userId, ...dashboard }]))
      .catch((error) => console.error('Firestore : impact non copié :', error.message));
  },

  /** Dernier tableau de bord copié, ou null (Firestore indisponible ou vide). */
  async readDashboard(userId) {
    if (!enabled) return null;
    const doc = await store.readDoc(DASHBOARDS, userId);
    if (!doc) return null;
    const { id: _id, ...dashboard } = doc;
    return dashboard;
  },

  /**
   * Copie d'un compte, pour vérifier son statut quand MySQL est
   * indisponible. null : pas de copie, ou Firestore indisponible.
   */
  async readUser(userId) {
    if (!enabled) return null;
    return store.readDoc('users', userId);
  },

  /**
   * Comptes copiés (sans mot de passe), avec le libellé de leur acteur, pour
   * la gestion des utilisateurs quand MySQL est indisponible. Plus récents
   * d'abord. null : Firestore non configuré.
   */
  async listUsers() {
    if (!enabled) return null;
    const [users, actors] = await Promise.all([store.readAll('users'), store.readAll('actors')]);
    const labels = new Map(actors.map((actor) => [String(actor.id), actor.label]));
    return users
      .map((user) => {
        const row = withoutSecrets('users', [plainDates(user)])[0];
        delete row.firebase_uid;
        return { ...row, actor_label: labels.get(String(row.actor_id)) ?? null };
      })
      .sort((a, b) => String(b.created_at ?? '').localeCompare(String(a.created_at ?? '')));
  },

  /**
   * Copie complète, attendue (script de rattrapage) : toutes les lignes, et
   * retrait des documents dont la ligne n'existe plus dans MySQL.
   */
  async syncAll() {
    const { now, counts } = await copyChanged(null);
    const removed = {};
    for (const table of Object.keys(MIRRORED_TABLES)) {
      const ids = new Set((await query(`SELECT id FROM ${table}`)).map((row) => String(row.id)));
      const stale = (await store.listIds(table)).filter((id) => !ids.has(id));
      if (stale.length > 0) await store.remove(table, stale);
      removed[table] = stale.length;
    }
    await store.writeState(now);
    lastSync = now;
    return { copied: counts, removed };
  },
};

/** Recopie après chaque requête réussie qui modifie des données. */
export function mirrorAfterWrite(req, res, next) {
  if (req.method !== 'GET' && req.method !== 'HEAD' && req.method !== 'OPTIONS') {
    res.on('finish', () => {
      if (res.statusCode < 400) firestoreMirror.changed();
    });
  }
  next();
}

/** Attend la fin des copies en cours (tests, arrêt propre). */
export async function flushFirestoreMirror() {
  await queue;
}

/** Pour les tests uniquement. `null` rétablit Firestore et la configuration. */
export function setFirestoreStore(fake) {
  store = fake ?? realStore;
  enabled = fake ? true : config.firestore.enabled;
  lastSync = undefined;
}
