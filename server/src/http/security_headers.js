import { config } from '../config.js';

/**
 * En-têtes de sécurité de toutes les réponses (l'API ne sert que du JSON et
 * des images) : pas d'interprétation du type, pas d'intégration dans une
 * page tierce, aucun script ni ressource chargée par une réponse.
 */
export function securityHeaders(req, res, next) {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
    // Les photos sont affichées par l'application web, servie d'une autre origine.
    'Cross-Origin-Resource-Policy': 'cross-origin',
    'X-Permitted-Cross-Domain-Policies': 'none',
  });
  // HTTPS imposé au navigateur, seulement derrière HTTPS (production).
  if (config.isProduction) {
    res.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  }
  next();
}

/** Réponses contenant un jeton ou des données personnelles : jamais en cache. */
export function noStore(req, res, next) {
  res.set('Cache-Control', 'no-store');
  next();
}
