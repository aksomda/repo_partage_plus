import { pathToFileURL } from 'node:url';

import { config } from '../config.js';
import { pool } from './pool.js';
import { firestoreMirror } from '../services/firestore_mirror.js';

/**
 * Copie complète de MySQL dans Firestore (toutes les tables copiées), et
 * retrait des documents dont la ligne a disparu. Sans effet sur MySQL.
 */
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (!config.firestore.enabled) {
    console.error(
      'Copie Firestore désactivée : renseignez FIREBASE_SERVICE_ACCOUNT dans server/.env',
    );
    process.exit(1);
  }
  firestoreMirror
    .syncAll()
    .then(({ copied, removed }) => {
      console.log('Copié dans Firestore :', copied);
      console.log('Retiré de Firestore (supprimé de MySQL) :', removed);
      return pool.end();
    })
    .catch((error) => {
      console.error('Échec de la copie Firestore :', error.message);
      process.exit(1);
    });
}
