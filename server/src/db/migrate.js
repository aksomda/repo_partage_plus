import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import mysql from 'mysql2/promise';

import { config } from '../config.js';
import { connectionOptions } from './pool.js';

const schemaUrl = new URL('./schema.sql', import.meta.url);

/** Acteurs créés au premier déploiement, modifiables ensuite par l'admin. */
export const DEFAULT_ACTORS = [
  // [code, libellé, description, icône, droits, inscription libre]
  ['particulier', 'Particulier', 'Je souhaite récupérer des produits', 'person', 'beneficiary', true],
  ['commercant', 'Commerçant', 'Je souhaite publier des produits', 'storefront', 'donor', true],
  ['restaurateur', 'Restaurateur', 'Je souhaite publier des produits', 'restaurant', 'donor', true],
  ['administrateur', 'Administrateur', 'Gère la plateforme', 'admin_panel_settings', 'admin', false],
];

/** Colonnes de `users` ajoutées après la première version du schéma. */
const USER_COLUMNS = {
  first_name: 'VARCHAR(80) NULL AFTER name',
  last_name: 'VARCHAR(80) NULL AFTER first_name',
  gender: "ENUM('male', 'female') NULL AFTER last_name",
  age: 'TINYINT UNSIGNED NULL AFTER gender',
  firebase_uid: 'VARCHAR(128) NULL AFTER password_hash',
  actor_id: 'INT UNSIGNED NULL AFTER role',
  email_verified_at: 'DATETIME NULL AFTER status_reason',
};

/** Met à niveau une base créée avec une version antérieure du schéma. */
async function upgrade(conn) {
  const [columns] = await conn.query(
    "SELECT COLUMN_NAME AS name FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users'",
  );
  const existing = new Set(columns.map((column) => column.name));
  for (const [column, definition] of Object.entries(USER_COLUMNS)) {
    if (!existing.has(column)) {
      await conn.query(`ALTER TABLE users ADD COLUMN ${column} ${definition}`);
    }
  }

  await conn.query(`ALTER TABLE users
    MODIFY password_hash VARCHAR(255) NULL,
    MODIFY status ENUM('pending', 'active', 'suspended') NOT NULL DEFAULT 'active'`);

  const [indexes] = await conn.query(
    "SELECT INDEX_NAME AS name FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users'",
  );
  if (!indexes.some((index) => index.name === 'uq_users_firebase_uid')) {
    await conn.query('ALTER TABLE users ADD UNIQUE KEY uq_users_firebase_uid (firebase_uid)');
  }

  const [constraints] = await conn.query(
    "SELECT CONSTRAINT_NAME AS name FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' AND CONSTRAINT_TYPE = 'FOREIGN KEY'",
  );
  if (!constraints.some((constraint) => constraint.name === 'fk_users_actor')) {
    await conn.query(
      'ALTER TABLE users ADD CONSTRAINT fk_users_actor FOREIGN KEY (actor_id) REFERENCES actors (id)',
    );
  }

  // Acteurs par défaut, uniquement si l'admin n'en a encore configuré aucun.
  const [[{ count }]] = await conn.query('SELECT COUNT(*) AS count FROM actors');
  if (count === 0) {
    for (const [index, [code, label, description, icon, role, selfSignup]] of DEFAULT_ACTORS.entries()) {
      await conn.query(
        `INSERT INTO actors (code, label, description, icon, permission_role, self_signup, sort_order)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [code, label, description, icon, role, selfSignup, index],
      );
    }
  }

  // Comptes antérieurs aux acteurs : rattachés d'après leurs droits.
  await conn.query(`UPDATE users u
    JOIN actors a ON a.code = CASE u.role
      WHEN 'beneficiary' THEN 'particulier'
      WHEN 'donor' THEN 'commercant'
      WHEN 'admin' THEN 'administrateur'
    END
    SET u.actor_id = a.id
    WHERE u.actor_id IS NULL`);
}

/**
 * Crée la base (en local) puis les tables.
 * `reset: true` supprime d'abord la base : réservé aux bases *_test.
 */
export async function migrate({ reset = false } = {}) {
  const conn = await mysql.createConnection({
    ...connectionOptions({ withDatabase: Boolean(config.db.url) }),
    multipleStatements: true,
  });

  try {
    await conn.query("SET time_zone = '+00:00'");

    if (!config.db.url) {
      const name = mysql.escapeId(config.db.database);
      if (reset) {
        if (!config.db.database.endsWith('_test')) {
          throw new Error('reset refusé : la base doit se terminer par _test');
        }
        await conn.query(`DROP DATABASE IF EXISTS ${name}`);
      }
      await conn.query(
        `CREATE DATABASE IF NOT EXISTS ${name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`,
      );
      await conn.query(`USE ${name}`);
    }

    await conn.query(await readFile(schemaUrl, 'utf8'));
    await upgrade(conn);
  } finally {
    await conn.end();
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  migrate()
    .then(() => console.log('Migration terminée'))
    .catch((error) => {
      console.error('Échec de la migration :', error.message);
      process.exit(1);
    });
}
