import { HttpError } from './errors.js';

/** Échecs tolérés par adresse e-mail (et adresse IP) sur la période. */
export const MAX_FAILURES = 5;

/** Échecs tolérés par adresse IP, toutes adresses e-mail confondues. */
export const MAX_FAILURES_PER_IP = 20;

/** Période de comptage, et durée du blocage une fois la limite atteinte. */
export const WINDOW_MS = 15 * 60_000;

/** Échecs récents (horodatages) par clé « ip|email » et « ip ». */
const failures = new Map();

function recent(key, now) {
  const kept = (failures.get(key) ?? []).filter((at) => now - at < WINDOW_MS);
  if (kept.length > 0) failures.set(key, kept);
  else failures.delete(key);
  return kept;
}

/**
 * Refuse (429) une connexion par mot de passe après trop d'échecs : contre
 * la recherche du mot de passe par essais successifs.
 */
export function assertLoginAllowed(ip, email, now = Date.now()) {
  const byAccount = recent(`${ip}|${email}`, now);
  const byIp = recent(ip, now);
  const blocked =
    (byAccount.length >= MAX_FAILURES && byAccount) ||
    (byIp.length >= MAX_FAILURES_PER_IP && byIp);
  if (blocked) {
    const minutes = Math.max(1, Math.ceil((blocked[0] + WINDOW_MS - now) / 60_000));
    throw new HttpError(
      429,
      `Trop de tentatives : réessayez dans ${minutes} min ou utilisez « Mot de passe oublié »`,
      { code: 'too_many_attempts', retry_after_minutes: minutes },
    );
  }
}

export function recordLoginFailure(ip, email, now = Date.now()) {
  for (const key of [`${ip}|${email}`, ip]) {
    failures.set(key, [...recent(key, now), now]);
  }
}

/** Connexion réussie : les échecs de ce compte sont oubliés. */
export function clearLoginFailures(ip, email) {
  failures.delete(`${ip}|${email}`);
}

/** Pour les tests uniquement. */
export function resetLoginAttempts() {
  failures.clear();
}
