import { randomUUID } from 'node:crypto';
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
    throw new HttpError(503, 'Firebase mal configuré sur le serveur (FIREBASE_SERVICE_ACCOUNT)', {
      code: 'firebase_unavailable',
    });
  }
  if (!app) {
    throw new HttpError(503, 'Authentification Firebase non configurée sur le serveur', {
      code: 'firebase_unavailable',
    });
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
      // L'application se connecte alors par MySQL (code firebase_unavailable).
      if (/network|internal-error|unavailable|timeout/i.test(error?.code ?? '')) {
        throw new HttpError(503, 'Firebase momentanément indisponible : réessayez plus tard', {
          code: 'firebase_unavailable',
        });
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

  /** Met à jour l'état du compte (sans toucher au mot de passe). */
  async updateUser(uid, { email, displayName, emailVerified, disabled }) {
    await firebaseAuth().updateUser(uid, { email, displayName, emailVerified, disabled });
  },

  /**
   * Crée ou remplace le compte [uid] avec le mot de passe haché de MySQL
   * (bcrypt) : Firebase n'a jamais besoin du mot de passe en clair.
   */
  async importUser({ uid, email, displayName, emailVerified, disabled, passwordHash }) {
    const result = await firebaseAuth().importUsers(
      [{ uid, email, displayName, emailVerified, disabled, passwordHash: Buffer.from(passwordHash) }],
      { hash: { algorithm: 'BCRYPT' } },
    );
    if (result.failureCount > 0) throw result.errors[0].error;
  },

  /** Recopie possible : compte de service renseigné (droits d'administration). */
  canSync() {
    return Boolean(config.firebase.serviceAccount);
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

  /**
   * Nouveau mot de passe. Non bloquant : il est aussi haché dans MySQL, qui
   * permet de se connecter en attendant. false : à recopier plus tard.
   */
  async setPassword(uid, password) {
    if (!uid) return true;
    try {
      await gateway.setPassword(uid, password);
      return true;
    } catch (error) {
      console.error('Firebase : mot de passe non modifié :', error.message);
      return false;
    }
  },

  /** Les comptes MySQL peuvent être recopiés dans Firebase (voir pushAccount). */
  get canSync() {
    try {
      return Boolean(gateway.importUser && (gateway.canSync?.() ?? true));
    } catch {
      return false;
    }
  },

  /**
   * Recopie un compte MySQL dans Firebase Auth et renvoie son uid (null :
   * rien à recopier). Compte sans uid (créé pendant une panne de Firebase),
   * ou mot de passe changé pendant la panne : compte importé avec le
   * mot de passe haché de MySQL. Sinon, seul l'état est mis à jour (le
   * mot de passe Firebase, peut-être plus récent, est gardé). Lève une
   * erreur si Firebase est encore injoignable.
   */
  async pushAccount(user) {
    // Inscription pendant une panne : un compte Firebase a pu être créé
    // sous cette adresse ; l'adresse est prouvée par le code, on le reprend.
    const uid = user.firebase_uid ?? (await gateway.findUserByEmail(user.email))?.uid ?? null;
    const account = {
      email: user.email,
      displayName: user.name,
      emailVerified: Boolean(user.email_verified_at),
      disabled: user.status === 'suspended',
    };
    if (user.password_hash && (!user.firebase_uid || user.firebase_sync_password)) {
      const target = uid ?? randomUUID().replaceAll('-', '');
      await gateway.importUser({ uid: target, ...account, passwordHash: user.password_hash });
      return target;
    }
    if (!uid) return null;
    await gateway.updateUser(uid, account);
    return uid;
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
   * false : à recopier plus tard (voir firebase_sync.js).
   */
  async syncDisabled(uid, disabled) {
    if (!uid) return true;
    try {
      await gateway.setDisabled(uid, disabled);
      return true;
    } catch (error) {
      console.error('Firebase : statut non mis à jour :', error.message);
      return false;
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
    if (!uid) return true;
    try {
      await gateway.markEmailVerified(uid);
      return true;
    } catch (error) {
      console.error('Firebase : e-mail vérifié non enregistré :', error.message);
      return false;
    }
  },
};

/** Pour les tests uniquement. `null` rétablit l'accès réel. */
export function setFirebaseGateway(fake) {
  gateway = fake ?? realGateway;
}
