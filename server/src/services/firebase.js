import { cert, getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';

import { config } from '../config.js';
import { HttpError } from '../http/errors.js';

function parseServiceAccount(raw) {
  const text = raw.trim().startsWith('{') ? raw : Buffer.from(raw, 'base64').toString('utf8');
  return JSON.parse(text);
}

let auth = null;

function firebaseAuth() {
  if (auth) return auth;

  const { projectId, serviceAccount } = config.firebase;
  if (!projectId && !serviceAccount) {
    throw new HttpError(503, 'Authentification Firebase non configurée sur le serveur');
  }
  // Sans compte de service, seule la vérification des jetons fonctionne
  // (désactivation et e-mail vérifié côté Firebase sont alors ignorés).
  const app =
    getApps()[0] ??
    initializeApp(
      serviceAccount
        ? { credential: cert(parseServiceAccount(serviceAccount)), projectId: projectId ?? undefined }
        : { projectId },
    );
  auth = getAuth(app);
  return auth;
}

/**
 * Accès à Firebase Auth. Remplaçable dans les tests par `setFirebaseGateway`.
 */
const realGateway = {
  /** Vérifie un jeton d'identité Firebase et renvoie { uid, email }. */
  async verifyIdToken(idToken) {
    try {
      const decoded = await firebaseAuth().verifyIdToken(idToken);
      return { uid: decoded.uid, email: decoded.email?.toLowerCase() ?? null };
    } catch (error) {
      if (error instanceof HttpError) throw error;
      throw new HttpError(401, 'Session Firebase invalide ou expirée');
    }
  },

  async setDisabled(uid, disabled) {
    await firebaseAuth().updateUser(uid, { disabled });
  },

  async markEmailVerified(uid) {
    await firebaseAuth().updateUser(uid, { emailVerified: true });
  },
};

let gateway = realGateway;

export const firebase = {
  verifyIdToken: (idToken) => gateway.verifyIdToken(idToken),

  /**
   * Répercute un changement sur Firebase sans bloquer : MySQL reste la
   * référence (chaque requête relit le statut), Firebase n'est qu'une copie.
   */
  async syncDisabled(uid, disabled) {
    if (!uid) return;
    try {
      await gateway.setDisabled(uid, disabled);
    } catch (error) {
      console.error('Firebase : statut non mis à jour :', error.message);
    }
  },

  async syncEmailVerified(uid) {
    if (!uid) return;
    try {
      await gateway.markEmailVerified(uid);
    } catch (error) {
      console.error('Firebase : e-mail vérifié non enregistré :', error.message);
    }
  },
};

/** Pour les tests uniquement. `null` rétablit l'accès réel. */
export function setFirebaseGateway(fake) {
  gateway = fake ?? realGateway;
}
