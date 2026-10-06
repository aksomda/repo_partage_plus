// Test manuel de l'envoi SMTP : node test-mail.local.mjs [destinataire]
// (fichier local, à supprimer après le test)
import { checkMailer, sendMail } from './src/services/mailer.js';

const to = process.argv[2] ?? 'a.ksomda@gmail.com';
console.log(await checkMailer());
await sendMail({
  to,
  subject: 'Partage+ : test d’envoi SMTP',
  text: 'Si vous lisez ce message, l’envoi d’e-mails de Partage+ fonctionne.',
});
console.log(`E-mail de test envoyé à ${to}`);
process.exit(0);
