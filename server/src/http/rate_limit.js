import { config } from '../config.js';
import { HttpError } from './errors.js';

/** Au-delà, les compteurs expirés sont purgés (mémoire bornée). */
const SWEEP_THRESHOLD = 10_000;

/** Tous les compteurs créés, pour les vider dans les tests. */
const limiters = new Set();

/**
 * Compteur à fenêtre fixe, en mémoire : au plus [max] coups par clé sur
 * [windowMs]. Suffisant pour une seule instance du serveur.
 */
export class WindowCounter {
  constructor({ max, windowMs }) {
    this.max = max;
    this.windowMs = windowMs;
    this.hits = new Map();
    limiters.add(this);
  }

  #current(key, now) {
    const entry = this.hits.get(key);
    if (entry && entry.resetAt > now) return entry;
    if (this.hits.size >= SWEEP_THRESHOLD) this.#sweep(now);
    const fresh = { count: 0, resetAt: now + this.windowMs };
    this.hits.set(key, fresh);
    return fresh;
  }

  #sweep(now) {
    for (const [key, entry] of this.hits) {
      if (entry.resetAt <= now) this.hits.delete(key);
    }
  }

  /** Compte un coup ; renvoie l'état après ce coup. */
  hit(key, now = Date.now()) {
    const entry = this.#current(key, now);
    entry.count += 1;
    return this.#state(entry, now);
  }

  /** État sans compter de coup (limite déjà atteinte ?). */
  peek(key, now = Date.now()) {
    return this.#state(this.#current(key, now), now);
  }

  delete(key) {
    this.hits.delete(key);
  }

  reset() {
    this.hits.clear();
  }

  #state(entry, now) {
    return {
      allowed: entry.count <= this.max,
      blocked: entry.count >= this.max,
      remaining: Math.max(0, this.max - entry.count),
      retryAfterSeconds: Math.max(1, Math.ceil((entry.resetAt - now) / 1000)),
    };
  }
}

/**
 * Middleware : refuse (429) au-delà de [max] requêtes par adresse IP (ou
 * par [key]) sur [windowMs]. Contre le déni de service, la recherche de
 * codes par essais successifs et l'envoi massif d'e-mails ou de SMS.
 */
export function rateLimit({ name, max, windowMs, key = (req) => req.ip, message }) {
  const counter = new WindowCounter({ max, windowMs });
  return (req, res, next) => {
    if (!config.rateLimit.enabled) return next();
    const state = counter.hit(`${name}:${key(req)}`);
    res.set('RateLimit-Limit', String(max));
    res.set('RateLimit-Remaining', String(state.remaining));
    if (!state.allowed) {
      res.set('Retry-After', String(state.retryAfterSeconds));
      const minutes = Math.ceil(state.retryAfterSeconds / 60);
      throw new HttpError(
        429,
        message ?? `Trop de requêtes : réessayez dans ${minutes} min`,
        { code: 'rate_limited', retry_after_seconds: state.retryAfterSeconds },
      );
    }
    next();
  };
}

/** Pour les tests : vide tous les compteurs. */
export function resetRateLimits() {
  for (const counter of limiters) counter.reset();
}
