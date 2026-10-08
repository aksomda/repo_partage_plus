import { sendPush } from './push.js';

/**
 * Enregistre une notification in-app. L'application Flutter les récupère
 * via GET /api/notifications ; elle est aussi envoyée en push aux appareils
 * de l'utilisateur.
 *
 * `db` est le pool ou une connexion de transaction : dans une transaction,
 * le push ne part qu'après la validation (jamais pour une action annulée).
 */
export async function notify(db, userId, { type, title, body, data = null }) {
  // Invité (sans compte) : pas de notification dans l'application.
  if (!userId) return;
  await db.query(
    'INSERT INTO notifications (user_id, type, title, body, data) VALUES (?, ?, ?, ?, ?)',
    [userId, type, title, body, data ? JSON.stringify(data) : null],
  );
  const push = () => sendPush(userId, { type, title, body, data });
  if (Array.isArray(db.afterCommit)) {
    db.afterCommit.push(push);
  } else {
    push();
  }
}
