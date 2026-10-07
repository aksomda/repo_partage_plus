import { config } from '../config.js';
import { query } from '../db/pool.js';

/**
 * SMS des codes (activation, mot de passe oublié), en complément de l'e-mail.
 * Ne lève jamais d'erreur : l'e-mail reste le canal principal.
 *
 * Fournisseurs : `android-gateway` (application « SMS Gateway for Android »,
 * https://sms-gate.app, sur un téléphone avec carte SIM). Un service payant
 * s'ajoute dans PROVIDERS, puis se choisit par SMS_PROVIDER, sans autre
 * changement.
 */
const PROVIDERS = {
  'android-gateway': {
    async send({ to, text }, settings, fetchImpl) {
      const response = await fetchImpl(settings.gatewayUrl, {
        method: 'POST',
        headers: {
          Authorization: `Basic ${Buffer.from(`${settings.username}:${settings.password}`).toString('base64')}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ textMessage: { text }, phoneNumbers: [to] }),
        signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok) throw new Error(`passerelle SMS : HTTP ${response.status}`);
    },
  },
};

/** Pour les tests : remplace `fetch` vers la passerelle, `null` rétablit l'accès réel. */
let fetchImpl = null;
export function setSmsFetch(fake) {
  fetchImpl = fake;
}

/**
 * Numéro au format international (+22670000000) ; null s'il est inutilisable.
 * Sans indicatif, SMS_DEFAULT_COUNTRY_CODE est ajouté.
 */
export function normalizePhone(phone, countryCode = config.sms.defaultCountryCode) {
  if (typeof phone !== 'string') return null;
  let digits = phone.replace(/[\s.-]/g, '');
  if (digits.startsWith('00')) digits = `+${digits.slice(2)}`;
  if (!digits.startsWith('+')) digits = `${countryCode}${digits}`;
  return /^\+\d{8,15}$/.test(digits) ? digits : null;
}

/** Réserve un envoi dans le plafond du jour ; false si le plafond est atteint. */
async function takeDailySlot(limit) {
  await query('INSERT IGNORE INTO sms_daily (day, sent) VALUES (CURDATE(), 0)');
  const result = await query(
    'UPDATE sms_daily SET sent = sent + 1 WHERE day = CURDATE() AND sent < ?',
    [limit],
  );
  return result.affectedRows === 1;
}

/** true si le SMS est parti, false sinon (désactivé, pas de numéro, plafond, panne). */
export async function sendSms(phone, text) {
  const settings = config.sms;
  const provider = settings.provider && PROVIDERS[settings.provider];
  if (!provider) {
    if (settings.provider) console.warn(`SMS_PROVIDER inconnu : ${settings.provider}`);
    return false;
  }
  const to = normalizePhone(phone);
  if (!to) return false;
  try {
    if (!(await takeDailySlot(settings.dailyLimit))) {
      console.warn(`SMS non envoyé : plafond de ${settings.dailyLimit} SMS par jour atteint`);
      return false;
    }
  } catch (error) {
    console.error('SMS non envoyé :', error.message);
    return false;
  }
  try {
    await provider.send({ to, text }, settings, fetchImpl ?? fetch);
    return true;
  } catch (error) {
    // Envoi raté : il ne compte pas dans le plafond du jour.
    await query('UPDATE sms_daily SET sent = sent - 1 WHERE day = CURDATE() AND sent > 0').catch(
      () => {},
    );
    console.error('SMS non envoyé :', error.message);
    return false;
  }
}
