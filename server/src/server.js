import { app } from './app.js';
import { config } from './config.js';
import { scheduleFirebaseSync } from './services/firebase_sync.js';
import { firestoreMirror } from './services/firestore_mirror.js';
import { runScheduledJobs } from './services/jobs.js';
import { checkMailer } from './services/mailer.js';

// Une erreur oubliée dans une tâche de fond (MySQL ou Firebase injoignable…)
// est journalisée au lieu d'arrêter le serveur.
process.on('unhandledRejection', (reason) => {
  console.error('Erreur non gérée (le serveur continue) :', reason?.message ?? reason);
});

app.listen(config.port, () => {
  console.log(`API démarrée sur http://localhost:${config.port}`);
  console.log(
    config.firestore.enabled
      ? `Copie Firestore active (base ${config.firestore.databaseId}, toutes les tables)`
      : 'Copie Firestore désactivée : renseignez FIREBASE_SERVICE_ACCOUNT dans .env',
  );
  checkMailer().then(console.log);
  // Rattrape ce qui a changé pendant l'arrêt (tout, la première fois).
  firestoreMirror.changed();
  // Comptes modifiés pendant une panne de Firebase.
  scheduleFirebaseSync();
});

if (config.jobs.intervalMinutes > 0) {
  const run = () =>
    runScheduledJobs()
      .then((result) => console.log('Tâches planifiées :', result))
      .catch((error) => console.error('Échec des tâches planifiées :', error.message));

  run();
  setInterval(run, config.jobs.intervalMinutes * 60_000).unref();
}
