import { z } from 'zod';

import { query } from '../db/pool.js';

/**
 * Paramètres réglables par l'administrateur, avec leur valeur par défaut.
 * Durées en heures ; un maximum à 0 interdit l'action sans compte.
 */
export const SETTINGS = {
  guest_offer_max: { default: 10, min: 0, max: 1000 },
  guest_offer_window_hours: { default: 1, min: 1, max: 720 },
  guest_reservation_max: { default: 20, min: 0, max: 1000 },
  guest_reservation_window_hours: { default: 1, min: 1, max: 720 },
};

/** Modification partielle : seules les clés connues, dans leurs bornes. */
export const settingsSchema = z
  .object(
    Object.fromEntries(
      Object.entries(SETTINGS).map(([name, { min, max }]) => [
        name,
        z.coerce.number().int().min(min).max(max).optional(),
      ]),
    ),
  )
  .strict();

/** Tous les paramètres : valeurs enregistrées, sinon valeurs par défaut. */
export async function loadSettings() {
  const rows = await query('SELECT name, value FROM settings');
  const saved = Object.fromEntries(rows.map((row) => [row.name, row.value]));
  return Object.fromEntries(
    Object.entries(SETTINGS).map(([name, { default: value }]) => [name, saved[name] ?? value]),
  );
}

export async function saveSettings(values) {
  for (const [name, value] of Object.entries(values)) {
    if (value === undefined) continue;
    await query(
      'INSERT INTO settings (name, value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)',
      [name, value],
    );
  }
  return loadSettings();
}
