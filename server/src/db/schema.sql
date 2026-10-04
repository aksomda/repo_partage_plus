-- Schéma MySQL de Repas Partage Plus.
-- Idempotent : peut être rejoué à chaque déploiement (npm run db:migrate).
-- Toutes les dates DATETIME sont stockées en UTC.

-- Acteurs proposés à l'inscription (particulier, restaurateur…), configurés
-- par l'administrateur. `permission_role` fixe les droits dans l'API.
CREATE TABLE IF NOT EXISTS actors (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(40) NOT NULL,
  label VARCHAR(80) NOT NULL,
  description VARCHAR(255) NULL,
  icon VARCHAR(50) NULL,
  permission_role ENUM('donor', 'beneficiary', 'association', 'admin') NOT NULL,
  self_signup TINYINT(1) NOT NULL DEFAULT 1,
  active TINYINT(1) NOT NULL DEFAULT 1,
  sort_order SMALLINT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_actors_code (code)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Les colonnes ajoutées après la première version sont aussi créées sur les
-- bases existantes par migrate.js (CREATE TABLE IF NOT EXISTS n'y touche pas).
CREATE TABLE IF NOT EXISTS users (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  first_name VARCHAR(80) NULL,
  last_name VARCHAR(80) NULL,
  gender ENUM('male', 'female') NULL,
  age TINYINT UNSIGNED NULL,
  email VARCHAR(190) NOT NULL,
  -- NULL pour les comptes Firebase : le mot de passe est géré par Firebase Auth.
  password_hash VARCHAR(255) NULL,
  firebase_uid VARCHAR(128) NULL,
  role ENUM('donor', 'beneficiary', 'association', 'admin') NOT NULL,
  actor_id INT UNSIGNED NULL,
  phone VARCHAR(30) NULL,
  latitude DECIMAL(9, 6) NULL,
  longitude DECIMAL(9, 6) NULL,
  -- pending : inscrit, en attente du code reçu par e-mail.
  status ENUM('pending', 'active', 'suspended') NOT NULL DEFAULT 'active',
  status_reason VARCHAR(255) NULL,
  email_verified_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_users_email (email),
  UNIQUE KEY uq_users_firebase_uid (firebase_uid),
  KEY idx_users_role_status (role, status),
  CONSTRAINT fk_users_actor FOREIGN KEY (actor_id) REFERENCES actors (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Codes envoyés par e-mail : activation du compte, réinitialisation du mot de passe (stockés hachés).
CREATE TABLE IF NOT EXISTS email_otps (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id INT UNSIGNED NOT NULL,
  purpose ENUM('activation', 'password_reset') NOT NULL DEFAULT 'activation',
  code_hash CHAR(64) NOT NULL,
  expires_at DATETIME NOT NULL,
  attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,
  consumed_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_email_otps_user (user_id, created_at),
  CONSTRAINT fk_email_otps_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS associations (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id INT UNSIGNED NOT NULL,
  name VARCHAR(150) NOT NULL,
  registration_number VARCHAR(80) NULL,
  address VARCHAR(255) NULL,
  status ENUM('pending', 'approved', 'rejected') NOT NULL DEFAULT 'pending',
  review_reason VARCHAR(255) NULL,
  reviewed_by INT UNSIGNED NULL,
  reviewed_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_associations_user (user_id),
  KEY idx_associations_status (status),
  CONSTRAINT fk_associations_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_associations_reviewer FOREIGN KEY (reviewed_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS categories (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(80) NOT NULL,
  icon VARCHAR(50) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_categories_name (name)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Facteurs d'impact par catégorie : CO2 évité et repas équivalents par kg sauvé.
CREATE TABLE IF NOT EXISTS impact_factors (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  category_id INT UNSIGNED NOT NULL,
  co2_kg_per_kg DECIMAL(8, 3) NOT NULL,
  meals_per_kg DECIMAL(8, 3) NOT NULL DEFAULT 2.5,
  source VARCHAR(255) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_factors_category (category_id),
  CONSTRAINT fk_factors_category FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- donor_id NULL : offre publiée par un invité (guest_*), sans compte.
CREATE TABLE IF NOT EXISTS offers (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  donor_id INT UNSIGNED NULL,
  guest_first_name VARCHAR(80) NULL,
  guest_last_name VARCHAR(80) NULL,
  guest_phone VARCHAR(30) NULL,
  category_id INT UNSIGNED NOT NULL,
  title VARCHAR(150) NOT NULL,
  description TEXT NULL,
  initial_quantity INT UNSIGNED NOT NULL,
  quantity_available INT UNSIGNED NOT NULL,
  unit VARCHAR(30) NOT NULL DEFAULT 'portion',
  -- Facultatif : sert au calcul de l'impact quand il est connu.
  weight_kg DECIMAL(8, 2) NULL,
  -- Prix par unité en F CFA (0 = don gratuit), payé hors application.
  price DECIMAL(10, 2) NOT NULL DEFAULT 0,
  payment_info VARCHAR(255) NULL,
  -- Pays du publieur (d'après sa position au moment de la publication).
  country_code CHAR(2) NULL,
  country_name VARCHAR(80) NULL,
  expiry_date DATE NOT NULL,
  pickup_start DATETIME NOT NULL,
  pickup_end DATETIME NOT NULL,
  address VARCHAR(255) NOT NULL,
  latitude DECIMAL(9, 6) NOT NULL,
  longitude DECIMAL(9, 6) NOT NULL,
  -- Date de la photo (NULL : pas de photo) ; le fichier est dans offer_photos.
  photo_updated_at DATETIME NULL,
  status ENUM('pending', 'published', 'rejected', 'reserved', 'completed', 'expired', 'cancelled')
    NOT NULL DEFAULT 'published',
  moderation_reason VARCHAR(255) NULL,
  moderated_by INT UNSIGNED NULL,
  moderated_at DATETIME NULL,
  expiry_notified_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_offers_status_expiry (status, expiry_date),
  KEY idx_offers_donor (donor_id),
  KEY idx_offers_position (latitude, longitude),
  CONSTRAINT fk_offers_donor FOREIGN KEY (donor_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_offers_category FOREIGN KEY (category_id) REFERENCES categories (id),
  CONSTRAINT fk_offers_moderator FOREIGN KEY (moderated_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- beneficiary_id NULL : réservation faite par un invité (guest_*).
-- Photo d'une offre, gardée à part pour ne pas alourdir les listes.
CREATE TABLE IF NOT EXISTS offer_photos (
  offer_id INT UNSIGNED PRIMARY KEY,
  mime VARCHAR(30) NOT NULL,
  data MEDIUMBLOB NOT NULL,
  CONSTRAINT fk_offer_photos_offer FOREIGN KEY (offer_id) REFERENCES offers (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS reservations (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  offer_id INT UNSIGNED NOT NULL,
  beneficiary_id INT UNSIGNED NULL,
  guest_first_name VARCHAR(80) NULL,
  guest_last_name VARCHAR(80) NULL,
  guest_phone VARCHAR(30) NULL,
  quantity INT UNSIGNED NOT NULL,
  -- Montant dû (prix × quantité) et référence de la transaction faite hors application.
  amount DECIMAL(10, 2) NOT NULL DEFAULT 0,
  payment_reference VARCHAR(64) NULL,
  status ENUM('pending', 'confirmed', 'picked_up', 'cancelled') NOT NULL DEFAULT 'pending',
  pickup_code CHAR(6) NOT NULL,
  confirmed_at DATETIME NULL,
  picked_up_at DATETIME NULL,
  cancelled_at DATETIME NULL,
  reminder_sent_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_reservations_beneficiary (beneficiary_id, status),
  KEY idx_reservations_offer (offer_id, status),
  CONSTRAINT fk_reservations_offer FOREIGN KEY (offer_id) REFERENCES offers (id) ON DELETE CASCADE,
  CONSTRAINT fk_reservations_beneficiary FOREIGN KEY (beneficiary_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- E-mail facultatif du publieur, prévenu si l'offre est retirée par
-- l'administrateur. À part : jamais renvoyé par les SELECT o.* publics.
CREATE TABLE IF NOT EXISTS offer_contacts (
  offer_id INT UNSIGNED NOT NULL PRIMARY KEY,
  email VARCHAR(255) NOT NULL,
  CONSTRAINT fk_offer_contacts_offer FOREIGN KEY (offer_id) REFERENCES offers (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Jetons remis à un invité pour revoir ou annuler sa publication / réservation
-- depuis son appareil (stockés hachés, jamais renvoyés par les SELECT o.* / r.*).
CREATE TABLE IF NOT EXISTS guest_tokens (
  kind ENUM('offer', 'reservation') NOT NULL,
  target_id INT UNSIGNED NOT NULL,
  token_hash CHAR(64) NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (kind, target_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Publications et réservations sans compte, pour le quota réglé par
-- l'administrateur (par téléphone et par adresse IP). Jamais exposé.
CREATE TABLE IF NOT EXISTS guest_submissions (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  kind ENUM('offer', 'reservation') NOT NULL,
  -- Numéro réduit aux chiffres (et +) : « +226 70 » et « +22670 » comptent ensemble.
  phone VARCHAR(30) NOT NULL,
  ip VARCHAR(45) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_guest_submissions_phone (kind, phone, created_at),
  KEY idx_guest_submissions_ip (kind, ip, created_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Paramètres réglables par l'administrateur (valeurs par défaut dans
-- services/settings.js : une ligne n'existe qu'une fois modifiée).
CREATE TABLE IF NOT EXISTS settings (
  name VARCHAR(64) NOT NULL PRIMARY KEY,
  value INT NOT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Réponses déjà envoyées, par clé Idempotency-Key : une action rejouée par
-- l'application après une coupure réseau n'est jamais appliquée deux fois.
CREATE TABLE IF NOT EXISTS idempotency_keys (
  idem_key VARCHAR(64) NOT NULL,
  user_id INT UNSIGNED NOT NULL DEFAULT 0,
  method VARCHAR(10) NOT NULL,
  path VARCHAR(255) NOT NULL,
  status_code SMALLINT UNSIGNED NULL,
  response_body JSON NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (idem_key, user_id),
  KEY idx_idempotency_created (created_at)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS notifications (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id INT UNSIGNED NOT NULL,
  type VARCHAR(40) NOT NULL,
  title VARCHAR(150) NOT NULL,
  body VARCHAR(500) NOT NULL,
  data JSON NULL,
  read_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_notifications_user (user_id, read_at),
  CONSTRAINT fk_notifications_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Mini chat entre un utilisateur (avec compte) et l'administration : une
-- conversation par utilisateur (user_id), messages texte et/ou images.
CREATE TABLE IF NOT EXISTS messages (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id INT UNSIGNED NOT NULL,
  sender_id INT UNSIGNED NOT NULL,
  from_admin TINYINT(1) NOT NULL DEFAULT 0,
  body VARCHAR(2000) NULL,
  photos_count TINYINT UNSIGNED NOT NULL DEFAULT 0,
  -- Lu par le destinataire (l'utilisateur, ou un administrateur).
  read_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_messages_user (user_id, id),
  CONSTRAINT fk_messages_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_messages_sender FOREIGN KEY (sender_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Images jointes à un message (images uniquement : JPEG, PNG ou WebP).
CREATE TABLE IF NOT EXISTS message_photos (
  message_id INT UNSIGNED NOT NULL,
  position TINYINT UNSIGNED NOT NULL,
  mime VARCHAR(30) NOT NULL,
  data MEDIUMBLOB NOT NULL,
  PRIMARY KEY (message_id, position),
  CONSTRAINT fk_message_photos_message FOREIGN KEY (message_id) REFERENCES messages (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
