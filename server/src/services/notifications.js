/**
 * Enregistre une notification in-app. L'application Flutter les récupère
 * via GET /api/notifications et les affiche en notification locale.
 *
 * `db` est le pool ou une connexion de transaction.
 */
export async function notify(db, userId, { type, title, body, data = null }) {
  await db.query(
    'INSERT INTO notifications (user_id, type, title, body, data) VALUES (?, ?, ?, ?, ?)',
    [userId, type, title, body, data ? JSON.stringify(data) : null],
  );
}
