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
 * (technique) et offer_photos (images trop lourdes pour Firestore).
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
  for (const table of Object.keys(MIRRORED_TABLES)) {
    const rows = since
      ? await query(`SELECT * FROM ${table} WHERE updated_at >= ?`, [since])
      : await query(`SELECT * FROM ${table}`);
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
