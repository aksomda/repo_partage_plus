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

-- Codes d'activation envoyés par e-mail après l'inscription (stockés hachés).
CREATE TABLE IF NOT EXISTS email_otps (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id INT UNSIGNED NOT NULL,
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

CREATE TABLE IF NOT EXISTS offers (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  donor_id INT UNSIGNED NOT NULL,
  category_id INT UNSIGNED NOT NULL,
  title VARCHAR(150) NOT NULL,
  description TEXT NULL,
  initial_quantity INT UNSIGNED NOT NULL,
  quantity_available INT UNSIGNED NOT NULL,
  unit VARCHAR(30) NOT NULL DEFAULT 'portion',
  weight_kg DECIMAL(8, 2) NOT NULL,
  expiry_date DATE NOT NULL,
  pickup_start DATETIME NOT NULL,
  pickup_end DATETIME NOT NULL,
  address VARCHAR(255) NOT NULL,
  latitude DECIMAL(9, 6) NOT NULL,
  longitude DECIMAL(9, 6) NOT NULL,
  status ENUM('pending', 'published', 'rejected', 'reserved', 'completed', 'expired', 'cancelled')
    NOT NULL DEFAULT 'pending',
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

CREATE TABLE IF NOT EXISTS reservations (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  offer_id INT UNSIGNED NOT NULL,
  beneficiary_id INT UNSIGNED NOT NULL,
  quantity INT UNSIGNED NOT NULL,
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
  KEY idx_notifications_user (user_id, read_at),
  CONSTRAINT fk_notifications_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;
