import mysql from 'mysql2/promise';

import { config } from '../config.js';

/** Options de connexion communes au pool, aux migrations et aux tests. */
export function connectionOptions({ withDatabase = true } = {}) {
  const common = {
    timezone: 'Z',
    decimalNumbers: true,
    dateStrings: ['DATE'],
    ssl: config.db.ssl ? { rejectUnauthorized: true } : undefined,
  };

  if (config.db.url) {
    return { uri: config.db.url, ...common };
  }

  return {
    host: config.db.host,
    port: config.db.port,
    user: config.db.user,
    password: config.db.password,
    database: withDatabase ? config.db.database : undefined,
    ...common,
  };
}

export const pool = mysql.createPool({
  ...connectionOptions(),
  waitForConnections: true,
  connectionLimit: 10,
});

// Les DATETIME sont en UTC : NOW() et CURRENT_TIMESTAMP doivent l'être aussi.
pool.on('connection', (connection) => {
  connection.query("SET time_zone = '+00:00'");
});

// pool.query (échappement côté client) plutôt que execute : execute gère
// mal les paramètres de LIMIT/OFFSET sur MySQL 8.
export async function query(sql, params = []) {
  const [rows] = await pool.query(sql, params);
  return rows;
}

/** Exécute `fn(conn)` dans une transaction, avec rollback en cas d'erreur. */
export async function transaction(fn) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const result = await fn(conn);
    await conn.commit();
    return result;
  } catch (error) {
    await conn.rollback();
    throw error;
  } finally {
    conn.release();
  }
}
