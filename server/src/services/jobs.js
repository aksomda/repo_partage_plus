import { transaction } from '../db/pool.js';
import { syncFirebaseAccounts } from './firebase_sync.js';
import { firestoreMirror } from './firestore_mirror.js';
import { purgeFirebaseMails } from './mailer.js';
import { releaseQuantity } from '../routes/reservations.js';
import { notify } from './notifications.js';

/** Délai avant le début du créneau à partir duquel on envoie le rappel. */
const REMINDER_HOURS = 2;
/** Nombre de jours avant la DLC à partir duquel on alerte. */
const EXPIRY_DAYS = 1;

async function sendPickupReminders(conn) {
  const [rows] = await conn.query(
    `SELECT r.id, r.beneficiary_id, r.offer_id, r.pickup_code, o.title, o.address,
            COALESCE(r.slot_start, o.pickup_start) AS pickup_start,
            COALESCE(r.slot_end, o.pickup_end) AS pickup_end
     FROM reservations r
     JOIN offers o ON o.id = r.offer_id
     WHERE r.status = 'confirmed' AND r.reminder_sent_at IS NULL
       AND COALESCE(r.slot_start, o.pickup_start) <= NOW() + INTERVAL ? HOUR
       AND COALESCE(r.slot_end, o.pickup_end) > NOW()
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

/**
 * Réservation encore en attente à l'approche du créneau : le donateur est
 * invité à la confirmer (sinon le bénéficiaire ne peut pas retirer).
 */
async function sendConfirmReminders(conn) {
  const [rows] = await conn.query(
    `SELECT r.id, r.offer_id, o.donor_id, o.title,
            COALESCE(r.slot_start, o.pickup_start) AS pickup_start
     FROM reservations r
     JOIN offers o ON o.id = r.offer_id
     WHERE r.status = 'pending' AND r.confirm_reminder_sent_at IS NULL
       AND COALESCE(r.slot_start, o.pickup_start) <= NOW() + INTERVAL ? HOUR
       AND COALESCE(r.slot_end, o.pickup_end) > NOW()
     FOR UPDATE`,
    [REMINDER_HOURS],
  );

  for (const row of rows) {
    await notify(conn, row.donor_id, {
      type: 'confirm_reminder',
      title: 'Réservation à confirmer',
      body: `Une réservation de « ${row.title} » attend votre confirmation : le retrait commence bientôt.`,
      data: { reservation_id: row.id, offer_id: row.offer_id },
    });
    await conn.query('UPDATE reservations SET confirm_reminder_sent_at = NOW() WHERE id = ?', [
      row.id,
    ]);
  }
  return rows.length;
}

/**
 * Créneau choisi terminé sans retrait (l'offre a d'autres créneaux) :
 * réservation annulée, quantité rendue, bénéficiaire prévenu.
 */
async function expireMissedSlots(conn) {
  const [missed] = await conn.query(
    `SELECT r.id, r.beneficiary_id, r.offer_id, r.quantity, o.title
     FROM reservations r JOIN offers o ON o.id = r.offer_id
     WHERE r.status IN ('pending', 'confirmed') AND r.slot_end IS NOT NULL AND r.slot_end <= NOW()
     FOR UPDATE`,
  );
  for (const reservation of missed) {
    await conn.query(
      "UPDATE reservations SET status = 'cancelled', cancelled_at = NOW() WHERE id = ?",
      [reservation.id],
    );
    await releaseQuantity(conn, reservation);
    await notify(conn, reservation.beneficiary_id, {
      type: 'reservation_cancelled',
      title: 'Créneau manqué',
      body: `Le créneau choisi pour « ${reservation.title} » est passé : la réservation est annulée.`,
      data: { reservation_id: reservation.id, offer_id: reservation.offer_id },
    });
  }
  return missed.length;
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

/** Offre arrivée à sa DLC ou à la fin du créneau de retrait ; [o] : alias de la table. */
const expiredCondition = (o = 'offers') => `
  ${o}.status IN ('pending', 'published', 'reserved')
  AND (${o}.expiry_date < CURDATE() OR ${o}.pickup_end <= NOW())`;

async function expireOffers(conn) {
  const [cancelled] = await conn.query(
    `SELECT r.id, r.beneficiary_id, r.offer_id, o.title
     FROM reservations r JOIN offers o ON o.id = r.offer_id
     WHERE r.status IN ('pending', 'confirmed') AND ${expiredCondition('o')}
     FOR UPDATE`,
  );
  await conn.query(
    `UPDATE reservations SET status = 'cancelled', cancelled_at = NOW()
     WHERE status IN ('pending', 'confirmed')
       AND offer_id IN (SELECT id FROM (SELECT id FROM offers WHERE ${expiredCondition()}) AS expired)`,
  );
  // Le bénéficiaire apprend que sa réservation n'est plus valable.
  for (const reservation of cancelled) {
    await notify(conn, reservation.beneficiary_id, {
      type: 'reservation_cancelled',
      title: 'Réservation expirée',
      body: `« ${reservation.title} » n’a pas été retiré à temps : l’offre a expiré et la réservation est annulée.`,
      data: { reservation_id: reservation.id, offer_id: reservation.offer_id },
    });
  }
  const [result] = await conn.query(
    `UPDATE offers SET status = 'expired' WHERE ${expiredCondition()}`,
  );
  return result.affectedRows;
}

async function purgeIdempotencyKeys(conn) {
  await conn.query(
    'DELETE FROM idempotency_keys WHERE created_at < NOW() - INTERVAL 7 DAY',
  );
  // Au-delà de la plus longue période réglable (30 jours), inutile au quota.
  await conn.query(
    'DELETE FROM guest_submissions WHERE created_at < NOW() - INTERVAL 31 DAY',
  );
}

/** Exécute toutes les tâches ; sans effet si rien n'est à traiter. */
export async function runScheduledJobs() {
  const result = await transaction(async (conn) => {
    await purgeIdempotencyKeys(conn);
    return {
      pickup_reminders: await sendPickupReminders(conn),
      confirm_reminders: await sendConfirmReminders(conn),
      missed_slots: await expireMissedSlots(conn),
      expiry_alerts: await sendExpiryAlerts(conn),
      expired_offers: await expireOffers(conn),
    };
  });
  // Offres expirées, rappels et notifications créés par ces tâches.
  firestoreMirror.changed();
  // Les e-mails (codes d'activation) ne restent pas dans Firestore.
  const purgedMails = await purgeFirebaseMails();
  // Comptes modifiés pendant une panne de Firebase : nouvel essai.
  const firebaseAccounts = await syncFirebaseAccounts();
  return {
    ...result,
    ...(purgedMails > 0 ? { purged_mails: purgedMails } : {}),
    ...(firebaseAccounts > 0 ? { firebase_accounts: firebaseAccounts } : {}),
  };
}
