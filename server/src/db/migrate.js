import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import mysql from 'mysql2/promise';

import { config } from '../config.js';
import { connectionOptions } from './pool.js';

const schemaUrl = new URL('./schema.sql', import.meta.url);

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
