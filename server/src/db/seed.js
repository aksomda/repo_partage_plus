import { pathToFileURL } from 'node:url';

import bcrypt from 'bcryptjs';

import { config } from '../config.js';
import { insertDefaultCategories } from './migrate.js';
import { pool, transaction } from './pool.js';

export const DEMO_PASSWORD = 'Demo1234!';

const USERS = [
  // [nom, email, rôle, code de l'acteur]
  ['Admin Démo', 'admin@demo.local', 'admin', 'administrateur'],
  ['Boulangerie du Centre', 'commerce@demo.local', 'donor', 'commercant'],
  ['Restaurant Le Partage', 'restaurant@demo.local', 'donor', 'restaurateur'],
  ['Awa Bénéficiaire', 'beneficiaire@demo.local', 'beneficiary', 'particulier'],
  ['Solidarité Plus', 'association@demo.local', 'association', 'association'],
  ['Entraide Quartier', 'association2@demo.local', 'association', 'association'],
];

/** Décale la position de démo d'environ `km` vers le nord-est. */
function near(km) {
  const delta = km / 111;
  return [config.seed.lat + delta, config.seed.lng + delta];
}

/** Vide toutes les tables (utilisé par `npm run db:seed -- --fresh`). */
async function wipe() {
  await transaction(async (conn) => {
    await conn.query('SET FOREIGN_KEY_CHECKS = 0');
    for (const table of [
      'email_otps',
      'notifications',
      'reservations',
      'offers',
      'impact_factors',
      'categories',
      'associations',
      'users',
    ]) {
      await conn.query(`DELETE FROM ${table}`);
    }
    await conn.query('SET FOREIGN_KEY_CHECKS = 1');
  });
}

/**
 * Insère un jeu de données de démo. Sans effet si la base en contient déjà,
 * sauf avec `fresh: true` qui efface d'abord TOUTES les données.
 */
export async function seed({ fresh = false } = {}) {
  if (fresh) await wipe();

  const [[existing]] = await pool.query(
    "SELECT COUNT(*) AS count FROM users WHERE email = 'admin@demo.local'",
  );
  if (existing.count > 0) return false;

  const passwordHash = await bcrypt.hash(DEMO_PASSWORD, 10);

  await transaction(async (conn) => {
    // Déjà créées par la migration, sauf après --fresh.
    await insertDefaultCategories(conn, 'Valeurs indicatives pour la démo');
    const [categories] = await conn.query('SELECT id, name FROM categories');
    const categoryIds = Object.fromEntries(categories.map(({ id, name }) => [name, id]));

    const userIds = {};
    for (const [name, email, role, actorCode] of USERS) {
      const [lat, lng] = near(0.5);
      const [result] = await conn.query(
        `INSERT INTO users (name, email, password_hash, role, actor_id, phone, latitude, longitude,
           email_verified_at)
         VALUES (?, ?, ?, ?, (SELECT id FROM actors WHERE code = ?), ?, ?, ?, NOW())`,
        [name, email, passwordHash, role, actorCode, '+22600000000', lat, lng],
      );
      userIds[email] = result.insertId;
    }

    await conn.query(
      `INSERT INTO associations (user_id, name, registration_number, address, status, reviewed_by, reviewed_at)
       VALUES (?, 'Solidarité Plus', 'ASSO-2026-001', 'Quartier centre', 'approved', ?, NOW()),
              (?, 'Entraide Quartier', 'ASSO-2026-002', 'Quartier nord', 'approved', NULL, NULL)`,
      [
        userIds['association@demo.local'],
        userIds['admin@demo.local'],
        userIds['association2@demo.local'],
      ],
    );

    const bakery = userIds['commerce@demo.local'];
    const restaurant = userIds['restaurant@demo.local'];
    const offers = [
      // [donateur, catégorie, titre, quantité, unité, kg, jours avant DLC, km, statut]
      [bakery, 'Boulangerie', 'Pains et viennoiseries du jour', 20, 'pièce', 4, 1, 0.3, 'published'],
      [restaurant, 'Plats cuisinés', 'Riz sauce arachide', 15, 'portion', 6, 0, 1.2, 'published'],
      [bakery, 'Produits laitiers', 'Yaourts nature', 12, 'pot', 1.5, 2, 0.3, 'published'],
      [restaurant, 'Fruits et légumes', 'Panier de mangues', 8, 'panier', 10, 3, 2.5, 'published'],
      [restaurant, 'Épicerie', 'Sacs de riz 5 kg', 4, 'sac', 20, 30, 8, 'published'],
      [bakery, 'Boissons', 'Jus de bissap', 10, 'bouteille', 5, 5, 0.3, 'pending'],
    ];

    for (const [donor, category, title, quantity, unit, kg, days, km, status] of offers) {
      const [lat, lng] = near(km);
      await conn.query(
        `INSERT INTO offers (donor_id, category_id, title, description, initial_quantity,
           quantity_available, unit, weight_kg, expiry_date, pickup_start, pickup_end,
           address, latitude, longitude, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURDATE() + INTERVAL ? DAY,
           NOW() - INTERVAL 1 HOUR, CURDATE() + INTERVAL ? DAY + INTERVAL 20 HOUR,
           ?, ?, ?, ?)`,
        [
          donor,
          categoryIds[category],
          title,
          'Offre de démonstration',
          quantity,
          quantity,
          unit,
          kg,
          days,
          days,
          'Adresse de démonstration',
          lat,
          lng,
          status,
        ],
      );
    }

    // Un créneau par offre : toute la période de retrait.
    await conn.query(`INSERT INTO offer_slots (offer_id, start_at, end_at)
      SELECT o.id, o.pickup_start, o.pickup_end FROM offers o
      WHERE NOT EXISTS (SELECT 1 FROM offer_slots s WHERE s.offer_id = o.id)`);

    // Une offre payante (paiement Mobile Money hors application).
    await conn.query(
      `UPDATE offers SET price = 250, payment_info = 'Orange Money +226 70 00 00 00'
       WHERE title = 'Panier de mangues'`,
    );
  });

  return true;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  seed({ fresh: process.argv.includes('--fresh') })
    .then((created) => {
      console.log(
        created
          ? `Données de démo créées (mot de passe : ${DEMO_PASSWORD})`
          : 'Données de démo déjà présentes, rien à faire',
      );
      return pool.end();
    })
    .catch((error) => {
      console.error('Échec du seed :', error.message);
      process.exit(1);
    });
}
