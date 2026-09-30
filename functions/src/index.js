import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';

import { InputError, ModelError, refineRecommendations } from './refine.js';

initializeApp();

/**
 * Clé RodiumAI : secret stocké dans Google Secret Manager, jamais dans
 * l'application. `firebase functions:secrets:set RODIUM_API_KEY`
 */
const rodiumApiKey = defineSecret('RODIUM_API_KEY');

/** Modèle utilisé (identifiant RodiumAI « fournisseur/modèle »). */
const rodiumModel = defineString('RODIUM_MODEL', { default: 'openai/gpt-4o-mini' });

/** Appels IA autorisés par utilisateur et par heure (coût maîtrisé). */
const CALLS_PER_HOUR = 30;

/** Compteur par utilisateur dans Firestore (fenêtre glissante d'une heure). */
async function checkQuota(uid) {
  const ref = getFirestore().collection('ai_usage').doc(uid);
  await getFirestore().runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const now = Date.now();
    const data = doc.data();
    const fresh = !data || now - data.window_start > 3_600_000;
    if (!fresh && data.count >= CALLS_PER_HOUR) {
      throw new HttpsError('resource-exhausted', 'Trop de demandes : réessayez plus tard');
    }
    tx.set(
      ref,
      fresh
        ? { window_start: now, count: 1 }
        : { window_start: data.window_start, count: data.count + 1 },
    );
  });
}

/**
 * Affine le classement local des offres (100 au maximum) avec un LLM.
 * Appelée par l'application Flutter (Firebase Auth requis, anonyme accepté).
 * Toute erreur est renvoyée proprement : l'application garde alors son
 * classement local.
 */
export const refineRecommendationsAi = onCall(
  {
    region: 'europe-west1',
    secrets: [rodiumApiKey],
    timeoutSeconds: 30,
    memory: '256MiB',
    maxInstances: 10,
    // Passer à true une fois Firebase App Check configuré dans l'application.
    enforceAppCheck: false,
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Session Firebase requise');
    }
    await checkQuota(request.auth.uid);

    try {
      return await refineRecommendations(request.data, {
        apiKey: rodiumApiKey.value(),
        model: rodiumModel.value(),
      });
    } catch (error) {
      if (error instanceof InputError) {
        throw new HttpsError('invalid-argument', error.message);
      }
      if (error instanceof ModelError) {
        logger.warn('Affinage IA indisponible', { reason: error.message });
        throw new HttpsError('unavailable', 'Service d’IA indisponible');
      }
      logger.error('Erreur inattendue', error);
      throw new HttpsError('internal', 'Erreur interne');
    }
  },
);
