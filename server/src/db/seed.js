import { pathToFileURL } from 'node:url';

import bcrypt from 'bcryptjs';

import { config } from '../config.js';
import { pool, transaction } from './pool.js';

export const DEMO_PASSWORD = 'Demo1234!';

const CATEGORIES = [
  // [nom, icône, kg CO2 évité par kg, repas par kg]
  ['Fruits et légumes', 'eco', 0.9, 2.5],
  ['Boulangerie', 'bakery_dining', 1.4, 3],
  ['Plats cuisinés', 'restaurant', 3.5, 2.5],
  ['Produits laitiers', 'egg', 3.2, 2.5],
  ['Épicerie', 'shopping_basket', 2, 2.5],
  ['Boissons', 'local_drink', 0.6, 0],
];

const USERS = [
  // [nom, email, rôle, code de l'acteur]
  ['Admin Démo', 'admin@demo.local', 'admin', 'administrateur'],
  ['Boulangerie du Centre', 'commerce@demo.local', 'donor', 'commercant'],
  ['Restaurant Le Partage', 'restaurant@demo.local', 'donor', 'restaurateur'],
  ['Awa Bénéficiaire', 'beneficiaire@demo.local', 'beneficiary', 'particulier'],
  ['Solidarité Plus', 'association@demo.local', 'association', null],
  ['Entraide Quartier', 'association2@demo.local', 'association', null],
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
    const categoryIds = {};
    for (const [name, icon, co2, meals] of CATEGORIES) {
      const [result] = await conn.query(
        'INSERT INTO categories (name, icon) VALUES (?, ?)',
        [name, icon],
      );
      categoryIds[name] = result.insertId;
      await conn.query(
        'INSERT INTO impact_factors (category_id, co2_kg_per_kg, meals_per_kg, source) VALUES (?, ?, ?, ?)',
        [result.insertId, co2, meals, 'Valeurs indicatives pour la démo'],
      );
    }

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
              (?, 'Entraide Quartier', 'ASSO-2026-002', 'Quartier nord', 'pending', NULL, NULL)`,
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
