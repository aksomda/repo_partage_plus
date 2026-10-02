import { transaction } from '../db/pool.js';
import { firestoreMirror } from './firestore_mirror.js';
import { notify } from './notifications.js';

/** Délai avant le début du créneau à partir duquel on envoie le rappel. */
const REMINDER_HOURS = 2;
/** Nombre de jours avant la DLC à partir duquel on alerte. */
const EXPIRY_DAYS = 1;

async function sendPickupReminders(conn) {
  const [rows] = await conn.query(
    `SELECT r.id, r.beneficiary_id, r.offer_id, r.pickup_code,
            o.title, o.address, o.pickup_start, o.pickup_end
     FROM reservations r
     JOIN offers o ON o.id = r.offer_id
     WHERE r.status = 'confirmed' AND r.reminder_sent_at IS NULL
       AND o.pickup_start <= NOW() + INTERVAL ? HOUR
       AND o.pickup_end > NOW()
     FOR UPDATE`,
    [REMINDER_HOURS],
  );

  for (const row of rows) {
    await notify(conn, row.beneficiary_id, {
      type: 'pickup_reminder',
      title: 'Rappel de retrait',
      body: `Pensez à retirer « ${row.title} » (${row.address}). Code : ${row.pickup_code}.`,
      data: {
        reservation_id: row.id,
        offer_id: row.offer_id,
        pickup_start: row.pickup_start,
        pickup_end: row.pickup_end,
      },
    });
    await conn.query('UPDATE reservations SET reminder_sent_at = NOW() WHERE id = ?', [
      row.id,
    ]);
  }
  return rows.length;
}

async function sendExpiryAlerts(conn) {
  const [offers] = await conn.query(
    `SELECT id, donor_id, title, expiry_date, quantity_available
     FROM offers
     WHERE status IN ('published', 'reserved') AND expiry_notified_at IS NULL
       AND expiry_date <= CURDATE() + INTERVAL ? DAY
       AND expiry_date >= CURDATE()
     FOR UPDATE`,
    [EXPIRY_DAYS],
  );

  for (const offer of offers) {
    await notify(conn, offer.donor_id, {
      type: 'expiry_soon',
      title: 'DLC proche',
      body: `« ${offer.title} » arrive à sa date limite le ${offer.expiry_date}. Reste : ${offer.quantity_available}.`,
      data: { offer_id: offer.id, expiry_date: offer.expiry_date },
    });

    const [holders] = await conn.query(
      `SELECT id, beneficiary_id FROM reservations
       WHERE offer_id = ? AND status IN ('pending', 'confirmed')`,
      [offer.id],
    );
    for (const holder of holders) {
      await notify(conn, holder.beneficiary_id, {
        type: 'expiry_soon',
        title: 'DLC proche',
        body: `« ${offer.title} » expire le ${offer.expiry_date} : retirez-le vite.`,
        data: { offer_id: offer.id, reservation_id: holder.id },
      });
    }

    await conn.query('UPDATE offers SET expiry_notified_at = NOW() WHERE id = ?', [
      offer.id,
    ]);
  }
  return offers.length;
}

async function expireOffers(conn) {
  const expiredCondition = `
    status IN ('pending', 'published', 'reserved')
    AND (expiry_date < CURDATE() OR pickup_end <= NOW())`;

  await conn.query(
    `UPDATE reservations SET status = 'cancelled', cancelled_at = NOW()
     WHERE status IN ('pending', 'confirmed')
       AND offer_id IN (SELECT id FROM (SELECT id FROM offers WHERE ${expiredCondition}) AS expired)`,
  );
  const [result] = await conn.query(
    `UPDATE offers SET status = 'expired' WHERE ${expiredCondition}`,
  );
  return result.affectedRows;
}

async function purgeIdempotencyKeys(conn) {
  await conn.query(
    'DELETE FROM idempotency_keys WHERE created_at < NOW() - INTERVAL 7 DAY',
  );
}

/** Exécute toutes les tâches ; sans effet si rien n'est à traiter. */
export async function runScheduledJobs() {
  const result = await transaction(async (conn) => {
    await purgeIdempotencyKeys(conn);
    return {
      pickup_reminders: await sendPickupReminders(conn),
      expiry_alerts: await sendExpiryAlerts(conn),
      expired_offers: await expireOffers(conn),
    };
  });
  // Offres expirées, rappels et notifications créés par ces tâches.
  firestoreMirror.changed();
  return result;
}
