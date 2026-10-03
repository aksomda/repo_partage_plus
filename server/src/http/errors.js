import { ZodError } from 'zod';

import { isDatabaseUnavailable } from '../db/pool.js';

export class HttpError extends Error {
  constructor(status, message, details) {
    super(message);
    this.status = status;
    this.details = details;
  }
}

export const notFound = (what = 'Ressource') =>
  new HttpError(404, `${what} introuvable`);

export function notFoundHandler(req, res) {
  res.status(404).json({ error: `Route inconnue : ${req.method} ${req.path}` });
}

// Express reconnaît un gestionnaire d'erreurs à ses 4 paramètres.
export function errorHandler(error, req, res, next) {
  if (error instanceof HttpError) {
    return res
      .status(error.status)
      .json({ error: error.message, details: error.details });
  }

  if (error instanceof ZodError) {
    return res.status(400).json({
      error: 'Données invalides',
      details: error.issues.map((issue) => ({
        field: issue.path.join('.'),
        message: issue.message,
      })),
    });
  }

  if (error.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'JSON invalide' });
  }

  // Base arrêtée ou injoignable : réponse claire, le serveur continue.
  if (isDatabaseUnavailable(error)) {
    console.error('MySQL indisponible :', error.code ?? error.message);
    return res
      .status(503)
      .json({ error: 'Service momentanément indisponible : réessayez dans quelques instants' });
  }

  if (error.code === 'ER_DUP_ENTRY') {
    return res.status(409).json({ error: 'Cette valeur existe déjà' });
  }

  if (error.code === 'ER_ROW_IS_REFERENCED_2') {
    return res
      .status(409)
      .json({ error: 'Élément encore utilisé, suppression impossible' });
  }

  if (error.code === 'ER_NO_REFERENCED_ROW_2') {
    return res.status(400).json({ error: 'Référence inexistante' });
  }

  console.error(error);
  res.status(500).json({ error: 'Erreur interne du serveur' });
}
