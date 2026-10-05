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

/** Codes d'erreur indiquant que MySQL est injoignable (et non une requête fausse). */
const UNAVAILABLE_CODES = new Set([
  'ECONNREFUSED',
  'ECONNRESET',
  'ENOTFOUND',
  'ETIMEDOUT',
  'EHOSTUNREACH',
  'EAI_AGAIN',
  'PROTOCOL_CONNECTION_LOST',
  'PROTOCOL_SEQUENCE_TIMEOUT',
  'ER_CON_COUNT_ERROR',
  'ER_ACCESS_DENIED_ERROR',
  'ER_BAD_DB_ERROR',
  'ER_SERVER_SHUTDOWN',
]);

/** true si l'erreur vient d'une base MySQL arrêtée ou injoignable. */
export function isDatabaseUnavailable(error) {
  return Boolean(error && (UNAVAILABLE_CODES.has(error.code) || error.fatal === true));
}

// pool.query (échappement côté client) plutôt que execute : execute gère
// mal les paramètres de LIMIT/OFFSET sur MySQL 8.
export async function query(sql, params = []) {
  const [rows] = await pool.query(sql, params);
  return rows;
}

/**
 * Exécute `fn(conn)` dans une transaction, avec rollback en cas d'erreur.
 * `conn.afterCommit` reçoit les tâches à lancer seulement après la
 * validation (envoi des notifications push).
 */
export async function transaction(fn) {
  const conn = await pool.getConnection();
  const afterCommit = [];
  conn.afterCommit = afterCommit;
  try {
    await conn.beginTransaction();
    const result = await fn(conn);
    await conn.commit();
    for (const task of afterCommit) task();
    return result;
  } catch (error) {
    await conn.rollback();
    throw error;
  } finally {
    delete conn.afterCommit;
    conn.release();
  }
}
