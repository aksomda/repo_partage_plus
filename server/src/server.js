import { app } from './app.js';
import { config } from './config.js';
import { runScheduledJobs } from './services/jobs.js';

app.listen(config.port, () => {
  console.log(`API démarrée sur http://localhost:${config.port}`);
});

if (config.jobs.intervalMinutes > 0) {
  const run = () =>
    runScheduledJobs()
      .then((result) => console.log('Tâches planifiées :', result))
      .catch((error) => console.error('Échec des tâches planifiées :', error.message));

  run();
  setInterval(run, config.jobs.intervalMinutes * 60_000).unref();
}
