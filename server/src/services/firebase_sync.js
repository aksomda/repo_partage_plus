import { query } from '../db/pool.js';
import { firebase } from './firebase.js';

/**
 * Recopie dans Firebase Auth des changements faits pendant une panne de
 * Firebase (MySQL fonctionnant) : compte créé, mot de passe changé, e-mail
 * vérifié, compte désactivé ou réactivé. MySQL reste la référence : le
 * compte est marqué (users.firebase_sync_at) puis recopié en arrière-plan,
 * tout de suite puis à chaque passage des tâches planifiées, jusqu'à réussite.
 */

/** Comptes traités par passage. */
const BATCH = 100;

let queue = Promise.resolve();
let pending = false;
/** Désactivé pendant les tests : ils lancent la recopie eux-mêmes. */
let automatic = process.env.NODE_ENV !== 'test';

/**
 * Recopie les comptes marqués. Les comptes en attente de leur code
 * d'activation attendent (adresse e-mail pas encore prouvée). Renvoie le
 * nombre de comptes recopiés ; jamais d'erreur.
 */
export async function syncFirebaseAccounts() {
  if (!firebase.canSync) return 0;
  const users = await query(
    `SELECT id, name, email, password_hash, firebase_uid, firebase_sync_at,
            firebase_sync_password, status, email_verified_at
     FROM users
     WHERE firebase_sync_at IS NOT NULL AND status <> 'pending'
     ORDER BY firebase_sync_at LIMIT ?`,
    [BATCH],
  );
  let synced = 0;
  for (const user of users) {
    try {
      const uid = await firebase.pushAccount(user);
      // Marque effacée seulement si rien n'a changé depuis la lecture.
      await query(
        `UPDATE users SET firebase_uid = COALESCE(firebase_uid, ?),
                firebase_sync_at = NULL, firebase_sync_password = 0
         WHERE id = ? AND firebase_sync_at = ?`,
        [uid, user.id, user.firebase_sync_at],
      );
      synced += 1;
    } catch (error) {
      console.error(`Firebase : compte ${user.id} non recopié (nouvel essai plus tard) :`, error.message);
    }
  }
  return synced;
}

/** Lance une recopie en arrière-plan (une seule à la fois). */
export function scheduleFirebaseSync() {
  if (!automatic || pending) return;
  pending = true;
  queue = queue
    .then(() => {
      pending = false;
      return syncFirebaseAccounts();
    })
    .catch((error) => console.error('Firebase : recopie des comptes non faite :', error.message));
}

/**
 * Note qu'un compte doit être recopié dans Firebase ([password] : son mot
 * de passe aussi), puis lance la recopie.
 */
export async function markFirebaseSync(userId, { password = false } = {}) {
  await query(
    `UPDATE users SET firebase_sync_at = NOW(3),
            firebase_sync_password = firebase_sync_password OR ?
     WHERE id = ?`,
    [password, userId],
  );
  scheduleFirebaseSync();
}

/** Pour les tests uniquement. */
export function setFirebaseSyncAutomatic(value) {
  automatic = value;
}
