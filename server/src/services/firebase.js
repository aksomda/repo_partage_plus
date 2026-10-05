import { readFileSync } from 'node:fs';

import { cert, getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';

import { config } from '../config.js';
import { HttpError } from '../http/errors.js';

/** Compte de service : JSON brut, chemin d'un fichier .json, ou base64. */
function parseServiceAccount(raw) {
  const value = raw.trim();
  if (value.startsWith('{')) return JSON.parse(value);
  if (value.toLowerCase().endsWith('.json')) {
    return JSON.parse(readFileSync(value.replace(/^["']|["']$/g, ''), 'utf8'));
  }
  return JSON.parse(Buffer.from(value, 'base64').toString('utf8'));
}

let auth = null;

/** Application Firebase Admin partagée (Auth, Firestore), ou null si non configurée. */
export function firebaseApp() {
  const { projectId, serviceAccount } = config.firebase;
  if (!projectId && !serviceAccount) return null;
  // Sans compte de service, seule la vérification des jetons fonctionne
  // (désactivation, e-mail vérifié et copie Firestore sont alors ignorés).
  return (
    getApps()[0] ??
    initializeApp(
      serviceAccount
        ? { credential: cert(parseServiceAccount(serviceAccount)), projectId: projectId ?? undefined }
        : { projectId },
    )
  );
}

function firebaseAuth() {
  if (auth) return auth;

  let app;
  try {
    app = firebaseApp();
  } catch (error) {
    // Compte de service illisible (chemin erroné, JSON invalide) : c'est la
    // configuration du serveur qui est en cause, pas la session.
    console.error('Firebase : compte de service illisible :', error.message);
    throw new HttpError(503, 'Firebase mal configuré sur le serveur (FIREBASE_SERVICE_ACCOUNT)');
  }
  if (!app) {
    throw new HttpError(503, 'Authentification Firebase non configurée sur le serveur');
  }
  auth = getAuth(app);
  return auth;
}

/**
 * Accès à Firebase Auth. Remplaçable dans les tests par `setFirebaseGateway`.
 */
const realGateway = {
  /** Vérifie un jeton d'identité Firebase et renvoie { uid, email }. */
  async verifyIdToken(idToken) {
    const firebaseAuthClient = firebaseAuth();
    try {
      const decoded = await firebaseAuthClient.verifyIdToken(idToken);
      return { uid: decoded.uid, email: decoded.email?.toLowerCase() ?? null };
    } catch (error) {
      // Firebase injoignable (réseau, panne) : ce n'est pas la session qui est en cause.
      if (/network|internal-error|unavailable|timeout/i.test(error?.code ?? '')) {
        throw new HttpError(503, 'Firebase momentanément indisponible : réessayez plus tard');
      }
      throw new HttpError(401, 'Session Firebase invalide ou expirée');
    }
  },

  async setDisabled(uid, disabled) {
    await firebaseAuth().updateUser(uid, { disabled });
  },

  async markEmailVerified(uid) {
    await firebaseAuth().updateUser(uid, { emailVerified: true });
  },

  async setPassword(uid, password) {
    await firebaseAuth().updateUser(uid, { password });
  },

  /** Compte Firebase de cette adresse : { uid, createdAt }, ou null. */
  async findUserByEmail(email) {
    try {
      const user = await firebaseAuth().getUserByEmail(email);
      return { uid: user.uid, createdAt: new Date(user.metadata.creationTime) };
    } catch (error) {
      if (error?.code === 'auth/user-not-found') return null;
      throw error;
    }
  },

  async deleteUser(uid) {
    await firebaseAuth().deleteUser(uid);
  },

  async createUser({ email, password, displayName }) {
    const user = await firebaseAuth().createUser({
      email,
      password,
      displayName,
      emailVerified: true,
    });
    return user.uid;
  },
};

let gateway = realGateway;

export const firebase = {
  verifyIdToken: (idToken) => gateway.verifyIdToken(idToken),

  /** Nouveau mot de passe : bloquant, sinon l'utilisateur ne pourrait pas se connecter. */
  async setPassword(uid, password) {
    try {
      await gateway.setPassword(uid, password);
    } catch (error) {
      if (error instanceof HttpError) throw error;
      console.error('Firebase : mot de passe non modifié :', error.message);
      throw new HttpError(503, 'Firebase momentanément indisponible : réessayez plus tard');
    }
  },

  /**
   * Compte créé par l'administrateur, aussi dans Firebase si possible.
   * Non bloquant : sans Firebase, le compte reste local (mot de passe haché
   * dans MySQL, connexion par /auth/login). Renvoie l'uid, ou null.
   */
  async createAccount(account) {
    try {
      return (await gateway.createUser?.(account)) ?? null;
    } catch (error) {
      console.error('Firebase : compte non créé :', error.message);
      return null;
    }
  },

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

  /**
   * Supprime un compte Firebase « orphelin » : créé par une inscription
   * interrompue (aucun profil MySQL) depuis plus de [minAgeMs]. Sans lui,
   * l'adresse resterait bloquée si la personne recommence avec un autre mot
   * de passe. Renvoie true si un compte a été supprimé ; jamais d'erreur.
   */
  async releaseOrphan(email, { hasProfile, minAgeMs, now = new Date() }) {
    try {
      const user = await gateway.findUserByEmail?.(email);
      if (!user || (await hasProfile(user.uid))) return false;
      if (now - user.createdAt < minAgeMs) return false;
      await gateway.deleteUser(user.uid);
      return true;
    } catch (error) {
      console.error('Firebase : compte orphelin non libéré :', error.message);
      return false;
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
