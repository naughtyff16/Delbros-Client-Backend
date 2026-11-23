-- =====================================================================================================
-- Delbros Leasing — Client & Vendor Portal backend
-- 01_schema.sql : database, tables, indexes, audit protection triggers
-- Target       : MySQL 8.0+ (Amazon RDS for MySQL), InnoDB, utf8mb4
-- PDPA         : personal data columns hold AES-256-GCM ciphertext written and read only by the Node backend
--                (key in the backend .env, never in the database). Lookups use HMAC blind-index *_hash columns.
-- Conventions  : * Money DECIMAL(15,2) — never FLOAT/DOUBLE
--                * Timestamps DATETIME(3) in UTC (RDS parameter group time_zone = '+00:00');
--                  business dates (due dates, transfer dates, hire days) are DATE in Asia/Manila
--                * Business numbers (EU-000781, INV-MNL-00001101, C-00123) are the primary keys of documents
--                * row_version on editable records = optimistic locking ("someone else changed this")
--                * Master data is deactivated (is_active = 0), never deleted
-- Run order    : 01_schema → 02_core → 03..10 procedures → 20_seed_reference → 99_security
-- =====================================================================================================

CREATE DATABASE IF NOT EXISTS delbros_portal
  DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_0900_ai_ci;
USE delbros_portal;

SET sql_mode = 'STRICT_ALL_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,ONLY_FULL_GROUP_BY';

-- =====================================================================================================
-- 1. REFERENCE DATA & CONFIGURATION
-- =====================================================================================================

CREATE TABLE branches (
  branch_code        VARCHAR(10)   NOT NULL,
  branch_name        VARCHAR(100)  NOT NULL,
  region             VARCHAR(50)   NOT NULL,                 -- NCR, North Luzon, South Luzon, Visayas, Mindanao
  region_group       ENUM('Luzon','Visayas','Mindanao') NULL,
  gate_pass_prefix   VARCHAR(5)    NOT NULL,                 -- MNL, CAV … (gate pass = prefix + 4 digits)
  billing_entity     ENUM('DBL','NAK','KNX') NOT NULL DEFAULT 'DBL',  -- pay-to entity (Nakamura for Mindanao)
  is_head_office     TINYINT(1)    NOT NULL DEFAULT 0,
  issues_gate_passes TINYINT(1)    NOT NULL DEFAULT 1,
  address            VARCHAR(255)  NULL,
  manager_name       VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  phone              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  is_active          TINYINT(1)    NOT NULL DEFAULT 1,
  inactive_reason    VARCHAR(255)  NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (branch_code)
) ENGINE=InnoDB;

CREATE TABLE equipment_types (
  equipment_type     VARCHAR(30)   NOT NULL,                 -- e.g. 20FT_CHASSIS
  type_name          VARCHAR(100)  NOT NULL,
  sort_order         INT           NOT NULL DEFAULT 0,
  length_ft          SMALLINT      NULL,
  is_active          TINYINT(1)    NOT NULL DEFAULT 1,
  inactive_reason    VARCHAR(255)  NULL,
  PRIMARY KEY (equipment_type)
) ENGINE=InnoDB;

-- BR-18: effective-dated, never overwritten — a change closes the old row and opens a new one.
CREATE TABLE rate_cards (
  rate_card_id       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  equipment_type     VARCHAR(30)   NOT NULL,
  contract_type      ENUM('LTL','SPL','QLP') NOT NULL,
  contract_class     ENUM('A','Z','Q') NOT NULL,
  daily_rate         DECIMAL(15,2) NOT NULL,
  indemnity          DECIMAL(15,2) NOT NULL DEFAULT 0,
  valid_from         DATE          NOT NULL,
  valid_to           DATE          NULL,
  reason             VARCHAR(255)  NULL,
  created_by         VARCHAR(100)  NOT NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (rate_card_id),
  KEY ix_rate_cards_lookup (equipment_type, contract_type, valid_from),
  CONSTRAINT fk_rate_cards_eqt FOREIGN KEY (equipment_type) REFERENCES equipment_types (equipment_type)
) ENGINE=InnoDB;

-- System settings (NFR-006: rules change without a code release). is_public = readable before sign-in.
CREATE TABLE system_settings (
  setting_key        VARCHAR(100)  NOT NULL,
  setting_value      VARCHAR(1000) NOT NULL,
  value_type         ENUM('number','text','bool','list') NOT NULL DEFAULT 'text',
  description        VARCHAR(500)  NULL,
  is_public          TINYINT(1)    NOT NULL DEFAULT 0,
  is_pending_decision TINYINT(1)   NOT NULL DEFAULT 0,      -- "proposed default awaiting a Delbros decision"
  updated_by         VARCHAR(100)  NULL,
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (setting_key)
) ENGINE=InnoDB;

-- Document numbering: one counter per series (+ branch/year folded into series_key when needed).
-- Read with SELECT … FOR UPDATE inside sp_next_number → no duplicate numbers across concurrent sessions.
CREATE TABLE number_sequences (
  series_key         VARCHAR(60)   NOT NULL,                 -- 'EU', 'RSC', 'SOA:2026', 'GP:MNL'
  `last_value`       BIGINT UNSIGNED NOT NULL DEFAULT 0,      -- backticked: LAST_VALUE is a reserved word in MySQL 8.0
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (series_key)
) ENGINE=InnoDB;

CREATE TABLE roles (
  role_code          VARCHAR(30)   NOT NULL,
  role_name          VARCHAR(100)  NOT NULL,
  realm              ENUM('INTERNAL','CLIENT_PORTAL','VENDOR_PORTAL') NOT NULL,
  PRIMARY KEY (role_code)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 2. IDENTITY, SESSIONS, ACCESS REQUESTS
-- =====================================================================================================

CREATE TABLE users (
  user_id            VARCHAR(100)  NOT NULL,                 -- portal users: generated U-000001 (never the email — PDPA); staff: e.g. AE.JREYES
  realm              ENUM('INTERNAL','CLIENT_PORTAL','VENDOR_PORTAL') NOT NULL,
  full_name          VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  designation        VARCHAR(150)  NULL,
  email              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  email_hash         CHAR(64)      NOT NULL,              -- HMAC-SHA256 blind index: lower(trim(email)) — sign-in lookup, one email = one account
  mobile             VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  status             ENUM('Active','Inactive') NOT NULL DEFAULT 'Inactive',
  branch_code        VARCHAR(10)   NULL,
  all_branches       TINYINT(1)    NOT NULL DEFAULT 0,       -- branchAccess = 'ALL'
  client_code        VARCHAR(20)   NULL,                     -- CLIENT_PORTAL users only
  vendor_id          VARCHAR(20)   NULL,                     -- VENDOR_PORTAL users only
  password_hash      VARCHAR(255)  NOT NULL,                 -- argon2id / bcrypt, produced by Node — never plain text
  must_change_password TINYINT(1)  NOT NULL DEFAULT 0,
  password_changed_at DATETIME(3)  NULL,
  failed_logins      INT           NOT NULL DEFAULT 0,
  locked_until       DATETIME(3)   NULL,
  last_login_at      DATETIME(3)   NULL,
  row_version        INT           NOT NULL DEFAULT 1,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (user_id),
  UNIQUE KEY ux_users_email_hash (email_hash),
  KEY ix_users_client (client_code),
  KEY ix_users_vendor (vendor_id),
  CONSTRAINT ck_users_realm_link CHECK (
       (realm = 'CLIENT_PORTAL' AND client_code IS NOT NULL AND vendor_id IS NULL)
    OR (realm = 'VENDOR_PORTAL' AND vendor_id IS NOT NULL AND client_code IS NULL)
    OR (realm = 'INTERNAL'      AND client_code IS NULL AND vendor_id IS NULL))
) ENGINE=InnoDB;

CREATE TABLE user_roles (
  user_id            VARCHAR(100)  NOT NULL,
  role_code          VARCHAR(30)   NOT NULL,
  PRIMARY KEY (user_id, role_code),
  CONSTRAINT fk_user_roles_user FOREIGN KEY (user_id) REFERENCES users (user_id),
  CONSTRAINT fk_user_roles_role FOREIGN KEY (role_code) REFERENCES roles (role_code)
) ENGINE=InnoDB;

CREATE TABLE user_branch_access (
  user_id            VARCHAR(100)  NOT NULL,
  branch_code        VARCHAR(10)   NOT NULL,
  PRIMARY KEY (user_id, branch_code),
  CONSTRAINT fk_uba_user FOREIGN KEY (user_id) REFERENCES users (user_id),
  CONSTRAINT fk_uba_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

-- Email one-time sign-in code. Node generates the 6-digit code and stores only its SHA-256 hash.
CREATE TABLE auth_otp_challenges (
  challenge_id       CHAR(48)      NOT NULL,                 -- random token returned to the browser
  user_id            VARCHAR(100)  NOT NULL,
  code_hash          CHAR(64)      NOT NULL,
  expires_at         DATETIME(3)   NOT NULL,
  resend_after       DATETIME(3)   NOT NULL,
  attempts           INT           NOT NULL DEFAULT 0,
  consumed_at        DATETIME(3)   NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (challenge_id),
  KEY ix_otp_user (user_id),
  CONSTRAINT fk_otp_user FOREIGN KEY (user_id) REFERENCES users (user_id)
) ENGINE=InnoDB;

-- Password reset links: single use, expiring. Only the SHA-256 hash of the emailed token is stored.
CREATE TABLE auth_password_resets (
  reset_id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  token_hash         CHAR(64)      NOT NULL,
  user_id            VARCHAR(100)  NOT NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  expires_at         DATETIME(3)   NOT NULL,
  used_at            DATETIME(3)   NULL,
  PRIMARY KEY (reset_id),
  UNIQUE KEY ux_reset_token (token_hash),
  KEY ix_reset_user (user_id),
  CONSTRAINT fk_reset_user FOREIGN KEY (user_id) REFERENCES users (user_id)
) ENGINE=InnoDB;

-- express-session store (express-mysql-session default schema). Sessions end centrally and time out.
CREATE TABLE sessions (
  session_id         VARCHAR(128)  CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  expires            INT UNSIGNED  NOT NULL,
  data               MEDIUMTEXT    CHARACTER SET utf8mb4 COLLATE utf8mb4_bin,
  PRIMARY KEY (session_id)
) ENGINE=InnoDB;

-- "Request portal access" (client or vendor) + the reviewer's single-use one-click approval link.
CREATE TABLE portal_access_requests (
  reference          VARCHAR(20)   NOT NULL,                 -- PAR-000001
  account_type       ENUM('client','vendor') NOT NULL,
  subject_id         VARCHAR(20)   NOT NULL,                 -- the draft client_code or vendor_id created with the request
  company_name       VARCHAR(200)  NOT NULL,
  tin                VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  tin_hash           CHAR(64)      NULL,                  -- HMAC-SHA256 blind index: first 9 TIN digits
  branch_code        VARCHAR(10)   NOT NULL,
  address            VARCHAR(255)  NOT NULL,
  contact_name       VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  email              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  email_hash         CHAR(64)      NOT NULL,              -- HMAC-SHA256 blind index: status lookup by reference + email
  phone              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  privacy_consent_at DATETIME(3)   NULL,
  status             ENUM('Submitted','Approved','Rejected') NOT NULL DEFAULT 'Submitted',
  reviewer_label     VARCHAR(150)  NOT NULL,
  reviewer_user_id   VARCHAR(100)  NULL,
  applicant_user_id  VARCHAR(100)  NULL,                     -- the inactive user created with the request
  approval_token_hash CHAR(64)     NULL,
  approval_expires_at DATETIME(3)  NULL,
  decided_at         DATETIME(3)   NULL,
  decided_by         VARCHAR(150)  NULL,
  decision_reason    VARCHAR(1000) NULL,
  billing_name       VARCHAR(200)  NULL,
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (reference),
  UNIQUE KEY ux_par_token (approval_token_hash),
  KEY ix_par_email (email_hash),
  CONSTRAINT fk_par_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 3. FILES (stored on the EC2 server in FILE_DIR). The database keeps metadata only; the file is at FILE_DIR/<storage_path>.
-- =====================================================================================================

CREATE TABLE files (
  file_id            CHAR(36)      NOT NULL,                 -- UUID, also the stored file name
  storage_path       VARCHAR(500)  NOT NULL,                 -- relative to FILE_DIR: purpose/yyyy-mm/<uuid>.<ext> (no personal data)
  original_name      VARCHAR(255)  NOT NULL,
  content_type       VARCHAR(100)  NOT NULL,
  size_bytes         BIGINT UNSIGNED NOT NULL,
  sha256             CHAR(64)      NULL,
  purpose            VARCHAR(40)   NOT NULL,                 -- ACCESS_DOC, TOPUP_PROOF, PAYMENT_PROOF, DISPUTE_ATTACHMENT, RESCUE_PHOTO, VENDOR_INVOICE …
  entity_type        VARCHAR(40)   NULL,                     -- set when the business record is saved
  entity_id          VARCHAR(40)   NULL,
  owner_client_code  VARCHAR(20)   NULL,                     -- scope check on download
  owner_vendor_id    VARCHAR(20)   NULL,
  upload_status      ENUM('Pending','Uploaded','Deleted') NOT NULL DEFAULT 'Pending',
  scan_status        ENUM('Pending','Clean','Infected','Failed') NOT NULL DEFAULT 'Pending',  -- Clean = content checked by the API on upload (real PDF/JPG/PNG); no virus scanner
  scanned_at         DATETIME(3)   NULL,
  uploaded_by        VARCHAR(100)  NULL,                     -- NULL for anonymous access-request uploads
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (file_id),
  UNIQUE KEY ux_files_path (storage_path),
  KEY ix_files_entity (entity_type, entity_id)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 4. CLIENTS & CREDIT
-- =====================================================================================================

CREATE TABLE clients (
  client_code        VARCHAR(20)   NOT NULL,                 -- C-00123
  client_name        VARCHAR(200)  NOT NULL,
  billing_name       VARCHAR(200)  NOT NULL,
  qb_name            VARCHAR(200)  NULL,
  tin                VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  tin_hash           CHAR(64)      NULL,                  -- HMAC-SHA256 blind index: first 9 TIN digits (BIR branch code dropped) — one TIN = one company
  vat_status         ENUM('VAT-registered','Non-VAT','Zero-rated') NOT NULL DEFAULT 'VAT-registered',
  address1           VARCHAR(255)  NOT NULL,
  address2           VARCHAR(255)  NULL,
  city               VARCHAR(100)  NULL,
  zip_code           VARCHAR(10)   NULL,
  country            VARCHAR(60)   NOT NULL DEFAULT 'PHILIPPINES',
  phone              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  email              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  ebilling_email     VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  billing_cycle      ENUM('Weekly','Monthly') NOT NULL DEFAULT 'Weekly',
  ae_user_id         VARCHAR(100)  NULL,                     -- Account Executive
  branch_code        VARCHAR(10)   NOT NULL,                 -- home branch
  status             ENUM('Active','Draft','Hold','Blacklist','Inactive') NOT NULL DEFAULT 'Draft',
  allow_lt           TINYINT(1)    NOT NULL DEFAULT 0,
  allow_st           TINYINT(1)    NOT NULL DEFAULT 0,
  allow_online       TINYINT(1)    NOT NULL DEFAULT 0,       -- portal EWA allowed
  allow_special      TINYINT(1)    NOT NULL DEFAULT 0,
  allow_rescue       TINYINT(1)    NOT NULL DEFAULT 0,
  is_legal           TINYINT(1)    NOT NULL DEFAULT 0,
  is_collection_agency TINYINT(1)  NOT NULL DEFAULT 0,
  credit_limit       DECIMAL(15,2) NULL,
  registration_source ENUM('Internal','Portal') NOT NULL DEFAULT 'Internal',
  notes              VARCHAR(2000) NULL,
  row_version        INT           NOT NULL DEFAULT 1,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (client_code),
  KEY ix_clients_tin (tin_hash),
  KEY ix_clients_status (status),
  CONSTRAINT fk_clients_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code),
  CONSTRAINT fk_clients_ae FOREIGN KEY (ae_user_id) REFERENCES users (user_id)
) ENGINE=InnoDB;

ALTER TABLE users ADD CONSTRAINT fk_users_client FOREIGN KEY (client_code) REFERENCES clients (client_code);

CREATE TABLE client_contacts (
  contact_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  client_code        VARCHAR(20)   NOT NULL,
  first_name         VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  last_name          VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  phone              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  email              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  email_hash         CHAR(64)      NULL,                  -- HMAC-SHA256 blind index: lower(trim(email)) — "email already on file"
  is_primary         TINYINT(1)    NOT NULL DEFAULT 0,
  is_signatory       TINYINT(1)    NOT NULL DEFAULT 0,
  is_active          TINYINT(1)    NOT NULL DEFAULT 1,
  PRIMARY KEY (contact_id),
  KEY ix_contacts_client (client_code),
  KEY ix_contacts_email (email_hash),
  CONSTRAINT fk_contacts_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

-- CWS branch access: branches enabled for EWA pickup / returns ("branches covered" on the Contracts page).
CREATE TABLE client_branch_access (
  client_code        VARCHAR(20)   NOT NULL,
  branch_code        VARCHAR(10)   NOT NULL,
  added_at           DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  added_reference    VARCHAR(40)   NULL,                     -- e.g. CRQ-000001 amendment
  PRIMARY KEY (client_code, branch_code),
  CONSTRAINT fk_cba_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_cba_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

-- Accreditation (portal reads its stage to explain "not yet accredited").
CREATE TABLE accreditations (
  accreditation_id   VARCHAR(20)   NOT NULL,
  client_code        VARCHAR(20)   NOT NULL,
  status             ENUM('Draft','Pending C&C','Pending Finance','Pending VP','Approved','Rejected') NOT NULL DEFAULT 'Draft',
  workflow_id        VARCHAR(20)   NULL,
  tin                VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  tin_hash           CHAR(64)      NULL,                  -- HMAC-SHA256 blind index: first 9 TIN digits
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (accreditation_id),
  KEY ix_accr_client (client_code),
  CONSTRAINT fk_accr_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

-- DBL-CNC-001: authorised, time-boxed override of one blocked gate (e.g. PORTAL_EWA while on hold).
CREATE TABLE gate_overrides (
  override_id        VARCHAR(20)   NOT NULL,
  client_code        VARCHAR(20)   NOT NULL,
  gate_action        VARCHAR(30)   NOT NULL,                 -- PORTAL_EWA, RESCUE_REQUEST, EWA_CREATE …
  reason             VARCHAR(1000) NOT NULL,
  valid_until        DATETIME(3)   NOT NULL,
  status             ENUM('Pending','Approved','Rejected') NOT NULL DEFAULT 'Pending',
  workflow_id        VARCHAR(20)   NULL,
  requested_by       VARCHAR(100)  NOT NULL,
  requested_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  approved_by        VARCHAR(100)  NULL,
  approved_at        DATETIME(3)   NULL,
  PRIMARY KEY (override_id),
  KEY ix_go_client (client_code, gate_action, status),
  CONSTRAINT fk_go_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

CREATE TABLE hold_events (
  hold_event_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  client_code        VARCHAR(20)   NOT NULL,
  event_type         ENUM('Auto Hold','Manual Hold','Reactivated','Re-Hold') NOT NULL,
  event_at           DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  event_by           VARCHAR(100)  NOT NULL,
  outstanding        DECIMAL(15,2) NOT NULL,
  days_overdue       INT           NULL,
  invoice_no         VARCHAR(30)   NULL,
  reason             VARCHAR(1000) NULL,
  workflow_id        VARCHAR(20)   NULL,
  PRIMARY KEY (hold_event_id),
  KEY ix_hold_client (client_code, event_at),
  CONSTRAINT fk_hold_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 5. CONTRACTS, CASH BONDS
-- =====================================================================================================

CREATE TABLE contracts (
  contract_no        VARCHAR(30)   NOT NULL,                 -- LTL-2026-0045
  client_code        VARCHAR(20)   NOT NULL,
  contract_type      ENUM('LTL','SPL','QLP') NOT NULL,
  contract_class     ENUM('A','Z','Q') NOT NULL,
  status             ENUM('Draft','Printed','Sent to Client','Signed','For Notarisation','Notarized','Active','Expired','Renewed','Terminated') NOT NULL DEFAULT 'Draft',
  effective_date     DATE          NOT NULL,
  expiry_date        DATE          NULL,                     -- NULL = open-ended (SPL)
  unit_qty           INT           NOT NULL,
  entitlement_by_type TINYINT(1)   NOT NULL DEFAULT 0,       -- 1: qty set for every type (0 = not entitled, on request)
  region             VARCHAR(50)   NOT NULL,
  branch_code        VARCHAR(10)   NULL,
  signatory_contact_id BIGINT UNSIGNED NULL,
  payment_method     VARCHAR(50)   NOT NULL,
  billing_cycle      ENUM('Weekly','Monthly') NOT NULL,
  credit_term_days   INT           NOT NULL DEFAULT 30,
  cash_deposit       DECIMAL(15,2) NOT NULL DEFAULT 0,       -- the contract's own cash bond
  lock_in_months     INT           NOT NULL DEFAULT 0,
  min_billing_days   INT           NULL,                     -- NULL = default by type (LTL/SPL 1, QLP 10)
  penalty_non_return DECIMAL(15,2) NOT NULL DEFAULT 0,
  penalty_deferred_check DECIMAL(15,2) NOT NULL DEFAULT 0,
  penalty_late_interest_pct DECIMAL(7,4) NOT NULL DEFAULT 0,
  penalty_dishonored_check DECIMAL(15,2) NOT NULL DEFAULT 0,
  version_no         INT           NOT NULL DEFAULT 1,
  renewal_of         VARCHAR(30)   NULL,
  renewed_to         VARCHAR(30)   NULL,
  renewal_state      ENUM('Renewed','Replaced by a new contract','Not renewed','Renewal requested','Decision pending') NULL,
  renewal_date       DATE          NULL,
  renewal_note       VARCHAR(1000) NULL,
  termination_reason VARCHAR(1000) NULL,
  termination_date   DATE          NULL,
  ae_user_id         VARCHAR(100)  NULL,
  created_by         VARCHAR(100)  NULL,
  row_version        INT           NOT NULL DEFAULT 1,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (contract_no),
  KEY ix_contracts_client (client_code, status),
  CONSTRAINT fk_contracts_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_contracts_signatory FOREIGN KEY (signatory_contact_id) REFERENCES client_contacts (contact_id)
) ENGINE=InnoDB;

-- Current rate & entitlement per equipment type (snapshot of the latest rate version).
CREATE TABLE contract_rates (
  contract_no        VARCHAR(30)   NOT NULL,
  equipment_type     VARCHAR(30)   NOT NULL,
  daily_rate         DECIMAL(15,2) NOT NULL,
  indemnity          DECIMAL(15,2) NOT NULL DEFAULT 0,
  entitled_qty       INT           NULL,                     -- NULL = no per-type cap (legacy contracts)
  template_rate      DECIMAL(15,2) NULL,
  PRIMARY KEY (contract_no, equipment_type),
  CONSTRAINT fk_cr_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no),
  CONSTRAINT fk_cr_eqt FOREIGN KEY (equipment_type) REFERENCES equipment_types (equipment_type)
) ENGINE=InnoDB;

-- BR-18 rate history: every version with its dates and reason.
CREATE TABLE contract_rate_versions (
  contract_no        VARCHAR(30)   NOT NULL,
  version_no         INT           NOT NULL,
  valid_from         DATE          NOT NULL,
  valid_to           DATE          NULL,
  reason             VARCHAR(500)  NOT NULL,
  created_by         VARCHAR(100)  NOT NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (contract_no, version_no),
  CONSTRAINT fk_crv_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no)
) ENGINE=InnoDB;

CREATE TABLE contract_rate_version_lines (
  contract_no        VARCHAR(30)   NOT NULL,
  version_no         INT           NOT NULL,
  equipment_type     VARCHAR(30)   NOT NULL,
  daily_rate         DECIMAL(15,2) NOT NULL,
  PRIMARY KEY (contract_no, version_no, equipment_type),
  CONSTRAINT fk_crvl_version FOREIGN KEY (contract_no, version_no) REFERENCES contract_rate_versions (contract_no, version_no)
) ENGINE=InnoDB;

-- Lifecycle history and renewal notices (3/2/1 months), one row per event.
CREATE TABLE contract_events (
  event_id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  contract_no        VARCHAR(30)   NOT NULL,
  status_label       VARCHAR(100)  NOT NULL,
  event_at           DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  event_by           VARCHAR(100)  NOT NULL,
  note               VARCHAR(1000) NULL,
  file_id            CHAR(36)      NULL,
  PRIMARY KEY (event_id),
  KEY ix_ce_contract (contract_no, event_at),
  CONSTRAINT fk_ce_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no)
) ENGINE=InnoDB;

-- Portal: renewal / amendment / termination requests.
CREATE TABLE contract_requests (
  request_id         VARCHAR(20)   NOT NULL,                 -- CRQ-000001
  client_code        VARCHAR(20)   NOT NULL,
  contract_no        VARCHAR(30)   NOT NULL,
  kind               ENUM('Renewal','Amendment','Termination') NOT NULL,
  details            VARCHAR(2000) NOT NULL,
  term_months        INT           NULL,
  change_area        VARCHAR(100)  NULL,
  effective_date     DATE          NULL,
  fee_estimate       DECIMAL(15,2) NULL,                     -- BR-15 estimate at submission
  status             ENUM('Submitted','Under review','Approved','Declined','Withdrawn') NOT NULL DEFAULT 'Submitted',
  is_open            TINYINT(1)    GENERATED ALWAYS AS (IF(status IN ('Submitted','Under review'), 1, NULL)) STORED,
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  submitted_by       VARCHAR(100)  NOT NULL,
  decided_at         DATETIME(3)   NULL,
  decided_by         VARCHAR(100)  NULL,
  decision_note      VARCHAR(1000) NULL,
  PRIMARY KEY (request_id),
  UNIQUE KEY ux_crq_one_open (contract_no, kind, is_open), -- one open request per kind (NULLs don't collide)
  KEY ix_crq_client (client_code),
  CONSTRAINT fk_crq_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no),
  CONSTRAINT fk_crq_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

CREATE TABLE cash_bonds (
  bond_id            VARCHAR(20)   NOT NULL,                 -- CB-000001
  client_code        VARCHAR(20)   NOT NULL,
  contract_no        VARCHAR(30)   NULL,                     -- contract-specific bond (Timeline 3)
  amount             DECIMAL(15,2) NOT NULL,
  date_received      DATE          NOT NULL,
  receipt_ref        VARCHAR(40)   NOT NULL,
  payment_method     VARCHAR(50)   NULL,
  received_by        VARCHAR(100)  NULL,
  status             ENUM('Held','Withdrawal Pending','Refunded','Applied') NOT NULL DEFAULT 'Held',
  outcome_kind       ENUM('Refunded','Transferred','Applied','Forfeited') NULL,
  outcome_at         DATETIME(3)   NULL,
  outcome_amount     DECIMAL(15,2) NULL,
  outcome_reference  VARCHAR(40)   NULL,
  outcome_note       VARCHAR(1000) NULL,
  outcome_to_contract VARCHAR(30)  NULL,
  notes              VARCHAR(1000) NULL,
  row_version        INT           NOT NULL DEFAULT 1,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (bond_id),
  KEY ix_cb_client (client_code),
  KEY ix_cb_contract (contract_no),
  CONSTRAINT fk_cb_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_cb_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no)
) ENGINE=InnoDB;

CREATE TABLE cash_bond_withdrawals (
  withdrawal_id      VARCHAR(20)   NOT NULL,                 -- CBW-000001
  bond_id            VARCHAR(20)   NOT NULL,
  amount             DECIMAL(15,2) NOT NULL,
  reason             VARCHAR(1000) NOT NULL,
  refundable_at_request DECIMAL(15,2) NOT NULL,
  early_exception    TINYINT(1)    NOT NULL DEFAULT 0,
  workflow_id        VARCHAR(20)   NOT NULL,
  status             ENUM('Pending','Approved — awaiting refund','Refunded','Rejected') NOT NULL DEFAULT 'Pending',
  requested_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  requested_by       VARCHAR(100)  NOT NULL,
  rejected_at        DATETIME(3)   NULL,
  reject_reason      VARCHAR(1000) NULL,
  refund_method      VARCHAR(50)   NULL,
  refund_date        DATE          NULL,
  refund_reference   VARCHAR(60)   NULL,
  refund_by          VARCHAR(100)  NULL,
  PRIMARY KEY (withdrawal_id),
  KEY ix_cbw_bond (bond_id),
  CONSTRAINT fk_cbw_bond FOREIGN KEY (bond_id) REFERENCES cash_bonds (bond_id)
) ENGINE=InnoDB;

-- BR-14 breakdown stored with the request (stage 'Request') and the re-check before refund (stage 'Recheck').
CREATE TABLE cash_bond_withdrawal_breakdowns (
  withdrawal_id      VARCHAR(20)   NOT NULL,
  stage              ENUM('Request','Recheck') NOT NULL,
  computed_at        DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  bond               DECIMAL(15,2) NOT NULL,
  unpaid             DECIMAL(15,2) NOT NULL,
  negative_wallet    DECIMAL(15,2) NOT NULL,
  pending_dm         DECIMAL(15,2) NOT NULL,
  posted_unsettled_dm DECIMAL(15,2) NOT NULL,
  deductions         DECIMAL(15,2) NOT NULL,
  refundable         DECIMAL(15,2) NOT NULL,
  sources_json       JSON          NOT NULL,                 -- {invoices:[{invoiceNo,balance}], pendingMemos:[…], unsettledMemos:[…]} snapshot
  PRIMARY KEY (withdrawal_id, stage),
  CONSTRAINT fk_cbwb_w FOREIGN KEY (withdrawal_id) REFERENCES cash_bond_withdrawals (withdrawal_id)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 6. FLEET & GATE (chassis, EWA, gate passes, EIR, returns)
-- =====================================================================================================

CREATE TABLE chassis (
  chassis_no         VARCHAR(30)   NOT NULL,                 -- DW-MNL-1003
  chassis_type       VARCHAR(30)   NOT NULL,
  plate_no           VARCHAR(20)   NULL,
  branch_code        VARCHAR(10)   NOT NULL,
  status             ENUM('New','Available','Allocated','On Hire','Breakdown','In Repair','Rescue','Parked','Unaccounted','Legal','Converted','Sold','Killed') NOT NULL DEFAULT 'Available',
  status_since       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  owner              VARCHAR(50)   NOT NULL DEFAULT 'Delbros',
  standard           ENUM('DW','Nakamura') NOT NULL DEFAULT 'DW',
  general_assessment ENUM('Roadworthy','Unroadworthy') NOT NULL DEFAULT 'Roadworthy',
  current_client_code VARCHAR(20)  NULL,
  current_contract_no VARCHAR(30)  NULL,
  current_gate_pass_no VARCHAR(20) NULL,
  axle_config        ENUM('2-axle','3-axle') NULL,
  hub_type           ENUM('Spoke','8-hole','10-hole') NULL,
  remarks            VARCHAR(1000) NULL,
  row_version        INT           NOT NULL DEFAULT 1,
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (chassis_no),
  KEY ix_chassis_avail (branch_code, chassis_type, status),
  KEY ix_chassis_client (current_client_code, status),
  KEY ix_chassis_contract (current_contract_no, status),
  CONSTRAINT fk_chassis_type FOREIGN KEY (chassis_type) REFERENCES equipment_types (equipment_type),
  CONSTRAINT fk_chassis_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

-- Equipment Withdrawal Authorization (EU-000781). Valid 24 h (gat.ewa_validity_hours, BR-06).
CREATE TABLE ewas (
  eu_no              VARCHAR(20)   NOT NULL,
  client_code        VARCHAR(20)   NOT NULL,
  contract_no        VARCHAR(30)   NOT NULL,
  branch_code        VARCHAR(10)   NOT NULL,                 -- pickup branch
  trucker            VARCHAR(150)  NOT NULL,
  truck_plate_no     VARCHAR(20)   NOT NULL,
  truck_orcr         VARCHAR(40)   NULL,
  driver_name        VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  driver_license_no  VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  driver_license_hash CHAR(64)      NOT NULL,              -- HMAC-SHA256 blind index: upper(licence) — drivers used before
  expected_pickup_at DATETIME(3)   NULL,
  remarks            VARCHAR(300)  NULL,
  status             ENUM('Active','Used','Partially Used','Expired','Extension Pending','Cancelled') NOT NULL DEFAULT 'Active',
  created_via        ENUM('Portal','Internal') NOT NULL,
  created_by         VARCHAR(100)  NOT NULL,
  created_at         DATETIME(3)   NOT NULL,
  valid_until        DATETIME(3)   NOT NULL,
  extension_count    INT           NOT NULL DEFAULT 0,
  cancelled_at       DATETIME(3)   NULL,
  cancelled_by       VARCHAR(100)  NULL,
  cancel_reason      VARCHAR(1000) NULL,
  expired_lapsed_units INT         NULL,
  row_version        INT           NOT NULL DEFAULT 1,
  updated_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (eu_no),
  KEY ix_ewas_client (client_code, created_at),
  KEY ix_ewas_contract (contract_no, status),
  KEY ix_ewas_expiry (status, valid_until),
  KEY ix_ewas_driver (client_code, driver_license_hash),
  CONSTRAINT fk_ewas_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_ewas_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no),
  CONSTRAINT fk_ewas_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

CREATE TABLE ewa_lines (
  eu_no              VARCHAR(20)   NOT NULL,
  equipment_type     VARCHAR(30)   NOT NULL,
  qty                INT           NOT NULL,
  PRIMARY KEY (eu_no, equipment_type),
  CONSTRAINT ck_ewa_lines_qty CHECK (qty >= 1),
  CONSTRAINT fk_ewal_ewa FOREIGN KEY (eu_no) REFERENCES ewas (eu_no),
  CONSTRAINT fk_ewal_eqt FOREIGN KEY (equipment_type) REFERENCES equipment_types (equipment_type)
) ENGINE=InnoDB;

-- Units released against an EWA line (written by Gate Out in the staff app).
CREATE TABLE ewa_line_chassis (
  eu_no              VARCHAR(20)   NOT NULL,
  equipment_type     VARCHAR(30)   NOT NULL,
  chassis_no         VARCHAR(30)   NOT NULL,
  gate_pass_no       VARCHAR(20)   NOT NULL,
  released_at        DATETIME(3)   NOT NULL,
  PRIMARY KEY (eu_no, chassis_no),
  CONSTRAINT fk_ewalc_line FOREIGN KEY (eu_no, equipment_type) REFERENCES ewa_lines (eu_no, equipment_type),
  CONSTRAINT fk_ewalc_chassis FOREIGN KEY (chassis_no) REFERENCES chassis (chassis_no)
) ENGINE=InnoDB;

CREATE TABLE ewa_extensions (
  extension_id       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  eu_no              VARCHAR(20)   NOT NULL,
  requested_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  requested_by       VARCHAR(100)  NOT NULL,
  reason             VARCHAR(1000) NOT NULL,
  workflow_id        VARCHAR(20)   NULL,
  status             ENUM('Pending','Approved','Rejected') NOT NULL DEFAULT 'Pending',
  decided_at         DATETIME(3)   NULL,
  decided_by         VARCHAR(100)  NULL,
  valid_until_before DATETIME(3)   NOT NULL,
  valid_until_after  DATETIME(3)   NULL,
  PRIMARY KEY (extension_id),
  KEY ix_ewax_ewa (eu_no),
  CONSTRAINT fk_ewax_ewa FOREIGN KEY (eu_no) REFERENCES ewas (eu_no)
) ENGINE=InnoDB;

CREATE TABLE gate_passes (
  gate_pass_no       VARCHAR(20)   NOT NULL,                 -- MNL0881
  direction          ENUM('OUT','IN') NOT NULL,
  chassis_no         VARCHAR(30)   NOT NULL,
  client_code        VARCHAR(20)   NOT NULL,
  contract_no        VARCHAR(30)   NOT NULL,
  eu_no              VARCHAR(20)   NULL,
  branch_code        VARCHAR(10)   NOT NULL,
  origin_branch_code VARCHAR(10)   NULL,                     -- Gate In at a different branch (BR-16)
  cross_branch_code  VARCHAR(20)   NULL,                     -- IT approval code for a cross-branch return
  trucker            VARCHAR(150)  NOT NULL,
  truck_plate_no     VARCHAR(20)   NOT NULL,
  truck_orcr         VARCHAR(40)   NULL,
  driver_name        VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  driver_license_no  VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  general_assessment ENUM('Roadworthy','Unroadworthy') NOT NULL,
  flat_tires         INT           NULL,
  vandalized         TINYINT(1)    NULL,
  signature_file_id  CHAR(36)      NULL,
  actual_event_at    DATETIME(3)   NOT NULL,
  encoded_at         DATETIME(3)   NOT NULL,
  encoded_by         VARCHAR(100)  NOT NULL,
  is_force_inbound   TINYINT(1)    NOT NULL DEFAULT 0,
  eir_no             VARCHAR(30)   NOT NULL,
  paired_gate_pass_no VARCHAR(20)  NULL,                     -- IN ↔ OUT
  remarks            VARCHAR(1000) NULL,
  PRIMARY KEY (gate_pass_no),
  KEY ix_gp_client (client_code, direction, actual_event_at),
  KEY ix_gp_contract (contract_no, direction),
  KEY ix_gp_chassis (chassis_no),
  KEY ix_gp_ewa (eu_no),
  CONSTRAINT fk_gp_chassis FOREIGN KEY (chassis_no) REFERENCES chassis (chassis_no),
  CONSTRAINT fk_gp_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_gp_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no),
  CONSTRAINT fk_gp_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

CREATE TABLE gate_pass_inspection_lines (
  gate_pass_no       VARCHAR(20)   NOT NULL,
  line_no            INT           NOT NULL,
  part               VARCHAR(100)  NOT NULL,
  branding           VARCHAR(50)   NULL,
  thread_depth       VARCHAR(20)   NULL,
  status_code        VARCHAR(20)   NOT NULL,
  qty                INT           NOT NULL DEFAULT 1,
  chargeable         DECIMAL(15,2) NOT NULL DEFAULT 0,       -- chargeable damage amount (ex VAT)
  PRIMARY KEY (gate_pass_no, line_no),
  CONSTRAINT fk_gpil_gp FOREIGN KEY (gate_pass_no) REFERENCES gate_passes (gate_pass_no)
) ENGINE=InnoDB;

CREATE TABLE eirs (
  eir_no             VARCHAR(30)   NOT NULL,                 -- EIR-MNL-000181
  gate_pass_out_no   VARCHAR(20)   NOT NULL,
  gate_pass_in_no    VARCHAR(20)   NULL,
  client_code        VARCHAR(20)   NOT NULL,
  chassis_no         VARCHAR(30)   NOT NULL,
  chassis_type       VARCHAR(30)   NOT NULL,
  contract_no        VARCHAR(30)   NOT NULL,
  depot_code         VARCHAR(10)   NOT NULL,
  eir_out_date       DATETIME(3)   NOT NULL,
  eir_in_date        DATETIME(3)   NULL,
  booking_no         VARCHAR(40)   NULL,
  reprint_count      INT           NOT NULL DEFAULT 0,
  PRIMARY KEY (eir_no),
  KEY ix_eir_client (client_code),
  CONSTRAINT fk_eir_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

-- Portal: client asks Delbros to collect an on-hire unit (proposed, Q-PTL-03).
CREATE TABLE return_requests (
  request_no         VARCHAR(20)   NOT NULL,                 -- RTN-000001
  client_code        VARCHAR(20)   NOT NULL,
  chassis_no         VARCHAR(30)   NOT NULL,
  contract_no        VARCHAR(30)   NULL,
  origin_branch_code VARCHAR(10)   NOT NULL,
  return_branch_code VARCHAR(10)   NOT NULL,
  preferred_date     DATE          NOT NULL,
  notes              VARCHAR(1000) NULL,
  status             ENUM('Requested','Scheduled','Completed','Cancelled') NOT NULL DEFAULT 'Requested',
  is_open            TINYINT(1)    GENERATED ALWAYS AS (IF(status IN ('Requested','Scheduled'), 1, NULL)) STORED,
  requested_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  requested_by       VARCHAR(100)  NOT NULL,
  PRIMARY KEY (request_no),
  UNIQUE KEY ux_rtn_one_open (chassis_no, is_open),
  KEY ix_rtn_client (client_code),
  CONSTRAINT fk_rtn_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_rtn_chassis FOREIGN KEY (chassis_no) REFERENCES chassis (chassis_no),
  CONSTRAINT fk_rtn_branch FOREIGN KEY (return_branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 7. ROADSIDE RESCUE
-- =====================================================================================================

CREATE TABLE rescues (
  rescue_no          VARCHAR(20)   NOT NULL,                 -- RSC-000042
  client_code        VARCHAR(20)   NOT NULL,
  chassis_no         VARCHAR(30)   NOT NULL,
  gate_pass_out_no   VARCHAR(20)   NULL,                     -- the hire the incident happened under
  branch_code        VARCHAR(10)   NOT NULL,
  location_text      VARCHAR(500)  NOT NULL,
  lat                DECIMAL(9,6)  NULL,
  lng                DECIMAL(9,6)  NULL,
  problem_type       VARCHAR(50)   NULL,
  problem_detail     VARCHAR(500)  NULL,
  incident           VARCHAR(2000) NOT NULL,
  load_status        ENUM('Loaded','Empty') NULL,
  scene_contact_name VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  scene_contact_phone VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  is_urgent          TINYINT(1)    NOT NULL DEFAULT 0,
  status             ENUM('Requested','Verified','Confirmed','Dispatched','In Progress','Completed','Cancelled','Blocked') NOT NULL DEFAULT 'Requested',
  requested_at       DATETIME(3)   NOT NULL,
  requested_via      ENUM('Portal','Internal') NOT NULL,
  requested_by       VARCHAR(100)  NOT NULL,
  blocked_reason     VARCHAR(1000) NULL,
  verified_by        VARCHAR(100)  NULL,
  confirmed_by       VARCHAR(100)  NULL,
  crew               VARCHAR(200)  NULL,
  rescue_vehicle     VARCHAR(100)  NULL,
  driver_name        VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  driver_phone       VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  dispatched_at      DATETIME(3)   NULL,
  eta                DATETIME(3)   NULL,
  onsite_assessment  VARCHAR(2000) NULL,
  completed_at       DATETIME(3)   NULL,
  completed_by       VARCHAR(100)  NULL,
  client_ack_name    VARCHAR(150)  NULL,
  acknowledged_at    DATETIME(3)   NULL,
  is_chargeable      TINYINT(1)    NOT NULL DEFAULT 1,
  one_way_km         DECIMAL(9,2)  NULL,
  rate_per_km        DECIMAL(15,2) NULL,
  tire_cost          DECIMAL(15,2) NULL,
  parts_cost         DECIMAL(15,2) NULL,
  total              DECIMAL(15,2) NULL,
  debit_memo_no      VARCHAR(20)   NULL,
  ewallet_balance_after DECIMAL(15,2) NULL,
  cancel_reason      VARCHAR(1000) NULL,
  cancelled_by       VARCHAR(100)  NULL,
  cancelled_at       DATETIME(3)   NULL,
  row_version        INT           NOT NULL DEFAULT 1,
  PRIMARY KEY (rescue_no),
  KEY ix_rsc_client (client_code, requested_at),
  KEY ix_rsc_chassis (chassis_no, status),
  CONSTRAINT fk_rsc_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_rsc_chassis FOREIGN KEY (chassis_no) REFERENCES chassis (chassis_no)
) ENGINE=InnoDB;

CREATE TABLE rescue_status_log (
  log_id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  rescue_no          VARCHAR(20)   NOT NULL,
  status             VARCHAR(30)   NOT NULL,
  status_at          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  status_by          VARCHAR(100)  NULL,
  PRIMARY KEY (log_id),
  KEY ix_rsl_rescue (rescue_no),
  CONSTRAINT fk_rsl_rescue FOREIGN KEY (rescue_no) REFERENCES rescues (rescue_no)
) ENGINE=InnoDB;

CREATE TABLE rescue_cost_lines (
  rescue_no          VARCHAR(20)   NOT NULL,
  line_no            INT           NOT NULL,
  kind               ENUM('Tire','Part') NOT NULL,
  part_code          VARCHAR(30)   NOT NULL,
  description        VARCHAR(200)  NOT NULL,
  qty                DECIMAL(9,2)  NOT NULL,
  unit_price         DECIMAL(15,2) NOT NULL,
  PRIMARY KEY (rescue_no, line_no),
  CONSTRAINT fk_rcl_rescue FOREIGN KEY (rescue_no) REFERENCES rescues (rescue_no)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 8. BILLING: invoices, receipts, memos, proof of payment, disputes, SOA sends
-- =====================================================================================================

CREATE TABLE invoices (
  invoice_no         VARCHAR(30)   NOT NULL,                 -- INV-MNL-00001101
  client_code        VARCHAR(20)   NOT NULL,
  contract_no        VARCHAR(30)   NULL,
  branch_code        VARCHAR(10)   NOT NULL,
  bill_type          VARCHAR(30)   NOT NULL,                 -- Lease, Repair, Rescue, Special …
  billing_cycle      VARCHAR(20)   NULL,
  batch_no           VARCHAR(30)   NULL,
  invoice_date       DATE          NOT NULL,
  period_start       DATE          NOT NULL,
  period_end         DATE          NOT NULL,
  subtotal           DECIMAL(15,2) NOT NULL,
  vat                DECIMAL(15,2) NOT NULL,
  total              DECIMAL(15,2) NOT NULL,
  amount_paid        DECIMAL(15,2) NOT NULL DEFAULT 0,       -- maintained by receipt applications
  credited           DECIMAL(15,2) NOT NULL DEFAULT 0,       -- maintained by applied credit memos
  credit_term_days   INT           NOT NULL DEFAULT 30,
  due_basis          ENUM('Legacy','Invoice date','Acknowledgment') NOT NULL DEFAULT 'Invoice date',
  due_date           DATE          NULL,                     -- NULL while awaiting acknowledgment (never overdue)
  acknowledged_at    DATETIME(3)   NULL,
  acknowledged_by    VARCHAR(100)  NULL,
  acknowledged_via   VARCHAR(40)   NULL,
  status             ENUM('Draft','Finalized','Sent','Cancelled') NOT NULL DEFAULT 'Draft',
  issued_at          DATETIME(3)   NULL,
  sent_to            VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  sent_at            DATETIME(3)   NULL,
  held_reason        VARCHAR(500)  NULL,
  cancel_reason      VARCHAR(500)  NULL,
  print_count        INT           NOT NULL DEFAULT 0,
  balance            DECIMAL(15,2) GENERATED ALWAYS AS (IF(status = 'Cancelled', 0, GREATEST(0, total - amount_paid - credited))) STORED,
  row_version        INT           NOT NULL DEFAULT 1,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (invoice_no),
  KEY ix_inv_client (client_code, status, invoice_date),
  KEY ix_inv_client_due (client_code, due_date),
  KEY ix_inv_contract (contract_no),
  CONSTRAINT fk_inv_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_inv_contract FOREIGN KEY (contract_no) REFERENCES contracts (contract_no),
  CONSTRAINT fk_inv_branch FOREIGN KEY (branch_code) REFERENCES branches (branch_code)
) ENGINE=InnoDB;

CREATE TABLE invoice_lines (
  invoice_no         VARCHAR(30)   NOT NULL,
  line_no            INT           NOT NULL,
  line_type          ENUM('Lease','Rescue','Repair','Park & Fix','Penalty','Adjustment','Damage','GPS','Special') NOT NULL,
  description        VARCHAR(500)  NOT NULL,
  chassis_no         VARCHAR(30)   NULL,
  equipment_type     VARCHAR(30)   NULL,
  rate_type          VARCHAR(30)   NULL,
  date_from          DATE          NULL,                     -- hire days covered (Manila dates)
  date_to            DATE          NULL,
  days               INT           NULL,
  rate               DECIMAL(15,2) NULL,
  amount             DECIMAL(15,2) NOT NULL,
  is_held            TINYINT(1)    NOT NULL DEFAULT 0,
  PRIMARY KEY (invoice_no, line_no),
  KEY ix_invl_chassis (chassis_no, line_type),
  CONSTRAINT fk_invl_inv FOREIGN KEY (invoice_no) REFERENCES invoices (invoice_no)
) ENGINE=InnoDB;

CREATE TABLE invoice_events (
  event_id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  invoice_no         VARCHAR(30)   NOT NULL,
  event_at           DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  event_by           VARCHAR(100)  NOT NULL,
  action             VARCHAR(60)   NOT NULL,
  note               VARCHAR(1000) NULL,
  PRIMARY KEY (event_id),
  KEY ix_inve_inv (invoice_no),
  CONSTRAINT fk_inve_inv FOREIGN KEY (invoice_no) REFERENCES invoices (invoice_no)
) ENGINE=InnoDB;

-- Provisional (PR) → Treasury clearance → Official Receipt (OR).
CREATE TABLE receipts (
  receipt_no         VARCHAR(30)   NOT NULL,                 -- OR-MNL-00000302 / PR-…
  receipt_type       ENUM('OR','PR','NVAR') NOT NULL,
  client_code        VARCHAR(20)   NOT NULL,
  receipt_date       DATE          NOT NULL,
  amount             DECIMAL(15,2) NOT NULL,
  unapplied          DECIMAL(15,2) NOT NULL DEFAULT 0,
  method             VARCHAR(50)   NOT NULL,
  reference          VARCHAR(80)   NULL,
  status             ENUM('Provisional','Cleared','OR Issued','Bounced','Cancelled') NOT NULL DEFAULT 'Provisional',
  or_no              VARCHAR(30)   NULL,                     -- on a PR: the OR it became
  pr_no              VARCHAR(30)   NULL,                     -- on an OR: the PR it came from
  check_no           VARCHAR(30)   NULL,
  check_bank         VARCHAR(100)  NULL,
  check_date         DATE          NULL,
  is_pdc             TINYINT(1)    NOT NULL DEFAULT 0,
  deposit_status     ENUM('Not deposited','Deposited','Cleared','Returned') NULL,
  cleared_at         DATETIME(3)   NULL,
  cleared_by         VARCHAR(100)  NULL,
  created_by         VARCHAR(100)  NOT NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (receipt_no),
  KEY ix_rcpt_client (client_code, receipt_date),
  CONSTRAINT fk_rcpt_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

CREATE TABLE receipt_applications (
  receipt_no         VARCHAR(30)   NOT NULL,
  invoice_no         VARCHAR(30)   NOT NULL,
  amount             DECIMAL(15,2) NOT NULL,
  PRIMARY KEY (receipt_no, invoice_no),
  KEY ix_ra_inv (invoice_no),
  CONSTRAINT fk_ra_rcpt FOREIGN KEY (receipt_no) REFERENCES receipts (receipt_no),
  CONSTRAINT fk_ra_inv FOREIGN KEY (invoice_no) REFERENCES invoices (invoice_no)
) ENGINE=InnoDB;

CREATE TABLE memos (
  memo_no            VARCHAR(20)   NOT NULL,                 -- CM-000010 / DM-000039
  memo_type          ENUM('Credit','Debit') NOT NULL,
  client_code        VARCHAR(20)   NOT NULL,
  category           VARCHAR(60)   NULL,
  reference_type     VARCHAR(40)   NOT NULL,                 -- Rescue, Job Order, Park & Fix, Invoice …
  reference_id       VARCHAR(40)   NULL,
  reference_invoice_no VARCHAR(30) NULL,                     -- memo raised against an invoice
  rescue_no          VARCHAR(20)   NULL,
  jo_no              VARCHAR(20)   NULL,
  amount             DECIMAL(15,2) NOT NULL,
  reason             VARCHAR(1000) NOT NULL,
  status             ENUM('Draft','Pending Approval','Approved','Posted','Rejected','Applied') NOT NULL DEFAULT 'Draft',
  applied_to         VARCHAR(30)   NULL,                     -- invoice it was applied to
  applied_at         DATETIME(3)   NULL,
  workflow_id        VARCHAR(20)   NULL,
  source             ENUM('Auto','Manual') NOT NULL DEFAULT 'Manual',
  created_by         VARCHAR(100)  NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (memo_no),
  KEY ix_memo_client (client_code, memo_type, status),
  CONSTRAINT fk_memo_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

-- Portal: proof of payment (does not change the balance until Accounting records the receipt).
CREATE TABLE payment_advices (
  advice_id          VARCHAR(20)   NOT NULL,                 -- PA-000001
  client_code        VARCHAR(20)   NOT NULL,
  invoice_no         VARCHAR(30)   NOT NULL,
  amount             DECIMAL(15,2) NOT NULL,
  paid_on            DATE          NOT NULL,
  method             VARCHAR(50)   NOT NULL,
  bank               VARCHAR(100)  NULL,
  reference          VARCHAR(80)   NOT NULL,
  reference_norm     VARCHAR(80)   GENERATED ALWAYS AS (UPPER(TRIM(reference))) STORED,
  proof_file_id      CHAR(36)      NOT NULL,
  remarks            VARCHAR(500)  NULL,
  status             ENUM('Submitted','Verified','Rejected') NOT NULL DEFAULT 'Submitted',
  receipt_no         VARCHAR(30)   NULL,
  reject_reason      VARCHAR(1000) NULL,
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  submitted_by       VARCHAR(100)  NOT NULL,
  PRIMARY KEY (advice_id),
  KEY ix_pa_inv (invoice_no),
  KEY ix_pa_ref (client_code, reference_norm),
  CONSTRAINT fk_pa_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_pa_inv FOREIGN KEY (invoice_no) REFERENCES invoices (invoice_no),
  CONSTRAINT fk_pa_file FOREIGN KEY (proof_file_id) REFERENCES files (file_id)
) ENGINE=InnoDB;

CREATE TABLE invoice_disputes (
  dispute_id         VARCHAR(20)   NOT NULL,                 -- DSP-000001
  client_code        VARCHAR(20)   NOT NULL,
  invoice_no         VARCHAR(30)   NOT NULL,
  reason             VARCHAR(200)  NOT NULL,
  details            VARCHAR(2000) NOT NULL,
  amount_disputed    DECIMAL(15,2) NULL,
  attachment_file_id CHAR(36)      NULL,
  status             ENUM('Submitted','Under review','Resolved','Rejected') NOT NULL DEFAULT 'Submitted',
  is_open            TINYINT(1)    GENERATED ALWAYS AS (IF(status IN ('Submitted','Under review'), 1, NULL)) STORED,
  resolution         VARCHAR(2000) NULL,
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  submitted_by       VARCHAR(100)  NOT NULL,
  PRIMARY KEY (dispute_id),
  UNIQUE KEY ux_dsp_one_open (invoice_no, is_open),
  CONSTRAINT fk_dsp_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_dsp_inv FOREIGN KEY (invoice_no) REFERENCES invoices (invoice_no),
  CONSTRAINT fk_dsp_file FOREIGN KEY (attachment_file_id) REFERENCES files (file_id)
) ENGINE=InnoDB;

CREATE TABLE soa_sends (
  soa_send_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  soa_no             VARCHAR(30)   NOT NULL,                 -- SOA-2026-00012
  client_code        VARCHAR(20)   NOT NULL,
  period_from        DATE          NULL,
  period_to          DATE          NULL,
  channel            ENUM('Email','Courier') NOT NULL,
  sent_to            VARCHAR(100)  NOT NULL,                 -- description only ("Your email", "Your email + company billing email") — no addresses (PDPA)
  tracking_no        VARCHAR(60)   NULL,
  sent_at            DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sent_by            VARCHAR(100)  NOT NULL,
  PRIMARY KEY (soa_send_id),
  KEY ix_soa_client (client_code),
  CONSTRAINT fk_soa_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 9. E-WALLET & TOP-UP
-- =====================================================================================================

CREATE TABLE ewallets (
  client_code        VARCHAR(20)   NOT NULL,
  balance            DECIMAL(15,2) NOT NULL DEFAULT 0,       -- maintained only by ewallet_txns postings
  minimum_balance    DECIMAL(15,2) NOT NULL,
  opening_receipt_no VARCHAR(30)   NULL,
  treasury_confirmed_by VARCHAR(100) NULL,
  treasury_confirmed_at DATETIME(3) NULL,
  created_by         VARCHAR(100)  NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  row_version        INT           NOT NULL DEFAULT 1,
  PRIMARY KEY (client_code),
  CONSTRAINT fk_ew_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

CREATE TABLE ewallet_txns (
  txn_id             VARCHAR(20)   NOT NULL,                 -- EWT-000001
  client_code        VARCHAR(20)   NOT NULL,
  txn_at             DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  txn_type           ENUM('Replenishment','Deduction','Adjustment','Reversal') NOT NULL,
  category           ENUM('Top-up','Rescue','Repair','Debit Memo','Contract-termination lease','Reversal','Adjustment') NOT NULL,
  amount             DECIMAL(15,2) NOT NULL,                 -- signed: + credit, − debit
  balance_after      DECIMAL(15,2) NOT NULL,
  reference_type     VARCHAR(40)   NOT NULL,
  reference_id       VARCHAR(40)   NULL,
  receipt_no         VARCHAR(30)   NULL,
  treasury_ref       VARCHAR(60)   NULL,
  posted_directly_by_treasury TINYINT(1) NOT NULL DEFAULT 0,
  reverses_txn_id    VARCHAR(20)   NULL,
  reversed_by_txn_id VARCHAR(20)   NULL,
  reason             VARCHAR(1000) NULL,
  posted_by          VARCHAR(100)  NOT NULL,
  PRIMARY KEY (txn_id),
  KEY ix_ewt_client (client_code, txn_at),
  KEY ix_ewt_ref (client_code, reference_id),
  CONSTRAINT fk_ewt_wallet FOREIGN KEY (client_code) REFERENCES ewallets (client_code)
) ENGINE=InnoDB;

CREATE TABLE topup_requests (
  topup_id           VARCHAR(20)   NOT NULL,                 -- TU-000001
  client_code        VARCHAR(20)   NOT NULL,
  amount             DECIMAL(15,2) NOT NULL,
  transfer_date      DATE          NOT NULL,
  method             VARCHAR(50)   NOT NULL,
  sending_bank       VARCHAR(100)  NULL,
  payment_ref        VARCHAR(80)   NOT NULL,                 -- stored exactly as entered by the client
  payment_ref_norm   VARCHAR(80)   GENERATED ALWAYS AS (UPPER(TRIM(payment_ref))) STORED,
  check_no           VARCHAR(30)   NULL,
  check_date         DATE          NULL,
  check_bank         VARCHAR(100)  NULL,
  proof_file_id      CHAR(36)      NOT NULL,
  remarks            VARCHAR(200)  NULL,
  resubmit_of        VARCHAR(20)   NULL,
  status             ENUM('Submitted','Confirmed by Treasury','Posted','Rejected') NOT NULL DEFAULT 'Submitted',
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  submitted_by       VARCHAR(100)  NOT NULL,
  bank_ref           VARCHAR(60)   NULL,
  receipt_no         VARCHAR(30)   NULL,
  confirmed_by       VARCHAR(100)  NULL,
  confirmed_at       DATETIME(3)   NULL,
  posted_by          VARCHAR(100)  NULL,
  posted_at          DATETIME(3)   NULL,
  txn_id             VARCHAR(20)   NULL,
  rejected_by        VARCHAR(100)  NULL,
  rejected_at        DATETIME(3)   NULL,
  reject_reason      VARCHAR(1000) NULL,
  PRIMARY KEY (topup_id),
  KEY ix_tu_client (client_code, submitted_at),
  KEY ix_tu_ref (client_code, payment_ref_norm),
  CONSTRAINT fk_tu_client FOREIGN KEY (client_code) REFERENCES clients (client_code),
  CONSTRAINT fk_tu_file FOREIGN KEY (proof_file_id) REFERENCES files (file_id),
  CONSTRAINT fk_tu_resubmit FOREIGN KEY (resubmit_of) REFERENCES topup_requests (topup_id)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 10. VENDORS & PROCUREMENT (vendor portal)
-- =====================================================================================================

CREATE TABLE vendors (
  vendor_id          VARCHAR(20)   NOT NULL,                 -- V-001
  vendor_name        VARCHAR(200)  NOT NULL,
  tin                VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  tin_hash           CHAR(64)      NULL,                  -- HMAC-SHA256 blind index: first 9 TIN digits
  address            VARCHAR(255)  NOT NULL,
  email              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  email_hash         CHAR(64)      NULL,                  -- HMAC-SHA256 blind index: lower(trim(email))
  phone              VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  contact_person     VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  payment_terms      VARCHAR(60)   NOT NULL DEFAULT 'To be agreed',
  vat_status         ENUM('VAT-registered','Non-VAT') NULL,
  status             ENUM('Active','Inactive','Pending','Blocked') NOT NULL DEFAULT 'Pending',
  status_reason      VARCHAR(500)  NULL,
  portal_access      TINYINT(1)    NOT NULL DEFAULT 0,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (vendor_id),
  KEY ix_vendors_tin (tin_hash),
  KEY ix_vendors_email (email_hash)
) ENGINE=InnoDB;

ALTER TABLE users ADD CONSTRAINT fk_users_vendor FOREIGN KEY (vendor_id) REFERENCES vendors (vendor_id);

CREATE TABLE parts (
  part_code          VARCHAR(30)   NOT NULL,
  description        VARCHAR(200)  NOT NULL,
  uom                VARCHAR(20)   NOT NULL,
  category           VARCHAR(60)   NOT NULL,
  standard_cost      DECIMAL(15,2) NOT NULL DEFAULT 0,
  rescue_price       DECIMAL(15,2) NULL,
  is_active          TINYINT(1)    NOT NULL DEFAULT 1,
  PRIMARY KEY (part_code)
) ENGINE=InnoDB;

CREATE TABLE purchase_orders (
  po_no              VARCHAR(20)   NOT NULL,                 -- PO-000154
  pr_no              VARCHAR(20)   NULL,
  vendor_id          VARCHAR(20)   NOT NULL,
  entity_code        VARCHAR(10)   NOT NULL,
  terms              VARCHAR(60)   NOT NULL,
  delivery_date      DATE          NOT NULL,
  status             ENUM('Draft','For Approval','Approved','Issued','Partially Received','Received','On Hold','Closed','Cancelled') NOT NULL DEFAULT 'Draft',
  workflow_id        VARCHAR(20)   NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (po_no),
  KEY ix_po_vendor (vendor_id, status),
  CONSTRAINT fk_po_vendor FOREIGN KEY (vendor_id) REFERENCES vendors (vendor_id)
) ENGINE=InnoDB;

CREATE TABLE po_lines (
  po_no              VARCHAR(20)   NOT NULL,
  part_code          VARCHAR(30)   NOT NULL,
  description        VARCHAR(200)  NOT NULL,
  qty                DECIMAL(12,2) NOT NULL,
  unit_price         DECIMAL(15,2) NOT NULL,
  qty_received       DECIMAL(12,2) NOT NULL DEFAULT 0,       -- maintained by receiving reports
  PRIMARY KEY (po_no, part_code),
  CONSTRAINT fk_pol_po FOREIGN KEY (po_no) REFERENCES purchase_orders (po_no),
  CONSTRAINT fk_pol_part FOREIGN KEY (part_code) REFERENCES parts (part_code)
) ENGINE=InnoDB;

CREATE TABLE receiving_reports (
  rr_no              VARCHAR(20)   NOT NULL,
  po_no              VARCHAR(20)   NOT NULL,
  received_date      DATE          NOT NULL,
  received_by        VARCHAR(100)  NOT NULL,
  warehouse_code     VARCHAR(20)   NOT NULL,
  has_discrepancy    TINYINT(1)    NOT NULL DEFAULT 0,
  condition_notes    VARCHAR(1000) NULL,
  PRIMARY KEY (rr_no),
  KEY ix_rr_po (po_no),
  CONSTRAINT fk_rr_po FOREIGN KEY (po_no) REFERENCES purchase_orders (po_no)
) ENGINE=InnoDB;

CREATE TABLE rr_lines (
  rr_no              VARCHAR(20)   NOT NULL,
  part_code          VARCHAR(30)   NOT NULL,
  qty_received       DECIMAL(12,2) NOT NULL,
  qty_rejected       DECIMAL(12,2) NOT NULL DEFAULT 0,
  item_condition     VARCHAR(60)   NOT NULL,
  PRIMARY KEY (rr_no, part_code),
  CONSTRAINT fk_rrl_rr FOREIGN KEY (rr_no) REFERENCES receiving_reports (rr_no)
) ENGINE=InnoDB;

CREATE TABLE vendor_invoices (
  vendor_invoice_id  VARCHAR(20)   NOT NULL,                 -- VI-000001
  vendor_id          VARCHAR(20)   NOT NULL,
  po_no              VARCHAR(20)   NOT NULL,
  rr_no              VARCHAR(20)   NULL,
  invoice_no         VARCHAR(60)   NOT NULL,                 -- the supplier's own number
  invoice_no_norm    VARCHAR(60)   GENERATED ALWAYS AS (UPPER(TRIM(invoice_no))) STORED,
  invoice_date       DATE          NOT NULL,
  amount             DECIMAL(15,2) NOT NULL,
  file_id            CHAR(36)      NOT NULL,
  status             ENUM('Submitted','Under Review','Approved','Paid','Rejected') NOT NULL DEFAULT 'Submitted',
  submitted_via      ENUM('Portal','Internal') NOT NULL,
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  reject_reason      VARCHAR(1000) NULL,
  resubmit_of        VARCHAR(20)   NULL,
  PRIMARY KEY (vendor_invoice_id),
  KEY ix_vi_vendor (vendor_id, invoice_no_norm),
  KEY ix_vi_po (po_no),
  CONSTRAINT fk_vi_vendor FOREIGN KEY (vendor_id) REFERENCES vendors (vendor_id),
  CONSTRAINT fk_vi_po FOREIGN KEY (po_no) REFERENCES purchase_orders (po_no),
  CONSTRAINT fk_vi_file FOREIGN KEY (file_id) REFERENCES files (file_id)
) ENGINE=InnoDB;

CREATE TABLE vendor_invoice_lines (
  vendor_invoice_id  VARCHAR(20)   NOT NULL,
  part_code          VARCHAR(30)   NOT NULL,
  qty                DECIMAL(12,2) NOT NULL,
  unit_price         DECIMAL(15,2) NOT NULL,
  PRIMARY KEY (vendor_invoice_id, part_code),
  CONSTRAINT fk_vil_vi FOREIGN KEY (vendor_invoice_id) REFERENCES vendor_invoices (vendor_invoice_id)
) ENGINE=InnoDB;

CREATE TABLE vendor_invoice_history (
  history_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  vendor_invoice_id  VARCHAR(20)   NOT NULL,
  status             VARCHAR(20)   NOT NULL,
  status_at          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  status_by          VARCHAR(100)  NOT NULL,
  note               VARCHAR(1000) NULL,
  PRIMARY KEY (history_id),
  KEY ix_vih_vi (vendor_invoice_id),
  CONSTRAINT fk_vih_vi FOREIGN KEY (vendor_invoice_id) REFERENCES vendor_invoices (vendor_invoice_id)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 11. WORKFLOW / APPROVALS
-- =====================================================================================================

CREATE TABLE workflows (
  workflow_id        VARCHAR(20)   NOT NULL,                 -- WF-00001
  matrix_code        VARCHAR(40)   NOT NULL,                 -- CASH_BOND_WITHDRAWAL, EWA_EXTENSION …
  title              VARCHAR(300)  NOT NULL,
  subject_type       VARCHAR(40)   NOT NULL,
  subject_id         VARCHAR(40)   NOT NULL,
  amount             DECIMAL(15,2) NULL,
  branch_code        VARCHAR(10)   NULL,
  requested_by       VARCHAR(100)  NOT NULL,
  requested_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  status             ENUM('Pending','Approved','Rejected','Cancelled') NOT NULL DEFAULT 'Pending',
  current_step       INT           NOT NULL DEFAULT 1,
  PRIMARY KEY (workflow_id),
  KEY ix_wf_subject (subject_type, subject_id),
  KEY ix_wf_status (status)
) ENGINE=InnoDB;

CREATE TABLE workflow_steps (
  workflow_id        VARCHAR(20)   NOT NULL,
  step_no            INT           NOT NULL,
  label              VARCHAR(100)  NOT NULL,
  roles_json         JSON          NOT NULL,                 -- ["CNC_OFFICER"] ; a role listed twice needs two distinct signers
  decision           ENUM('Pending','Approved','Rejected','Escalated','Skipped') NOT NULL DEFAULT 'Pending',
  decided_by         VARCHAR(100)  NULL,
  decided_at         DATETIME(3)   NULL,
  due_at             DATETIME(3)   NULL,                     -- escalation timer (wf.escalation_hours)
  PRIMARY KEY (workflow_id, step_no),
  CONSTRAINT fk_wfs_wf FOREIGN KEY (workflow_id) REFERENCES workflows (workflow_id)
) ENGINE=InnoDB;

CREATE TABLE workflow_signatures (
  workflow_id        VARCHAR(20)   NOT NULL,
  step_no            INT           NOT NULL,
  user_id            VARCHAR(100)  NOT NULL,
  role_code          VARCHAR(30)   NOT NULL,
  decision           ENUM('Approved','Rejected') NOT NULL,
  comment            VARCHAR(1000) NULL,
  signed_at          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (workflow_id, step_no, user_id),
  CONSTRAINT fk_wfsig_step FOREIGN KEY (workflow_id, step_no) REFERENCES workflow_steps (workflow_id, step_no)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 12. NOTIFICATIONS: rules, in-app notices, email outbox (delivery log)
-- =====================================================================================================

CREATE TABLE notification_rules (
  rule_id            VARCHAR(10)   NOT NULL,                 -- N08
  event_type         VARCHAR(60)   NOT NULL,
  description        VARCHAR(300)  NOT NULL,
  recipient_roles_json JSON        NOT NULL,
  include_client     TINYINT(1)    NOT NULL DEFAULT 0,
  include_ae         TINYINT(1)    NOT NULL DEFAULT 0,
  channels_json      JSON          NOT NULL,                 -- ["Email","In-App"]
  mode               ENUM('One-time','Repeat until ack') NOT NULL DEFAULT 'One-time',
  repeat_minutes     INT           NULL,
  escalation_hours   INT           NULL,
  escalate_to_json   JSON          NULL,
  template_subject   VARCHAR(300)  NULL,
  template_body      TEXT          NULL,
  is_active          TINYINT(1)    NOT NULL DEFAULT 1,
  PRIMARY KEY (rule_id),
  UNIQUE KEY ux_nr_event (event_type)
) ENGINE=InnoDB;

CREATE TABLE notifications (
  notification_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id            VARCHAR(100)  NOT NULL,
  event_type         VARCHAR(60)   NOT NULL,
  title              VARCHAR(300)  NOT NULL,
  body               VARCHAR(2000) NOT NULL,
  link               VARCHAR(300)  NULL,
  is_read            TINYINT(1)    NOT NULL DEFAULT 0,
  requires_ack       TINYINT(1)    NOT NULL DEFAULT 0,
  ack_at             DATETIME(3)   NULL,
  created_at         DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (notification_id),
  KEY ix_notif_user (user_id, is_read, created_at),
  CONSTRAINT fk_notif_user FOREIGN KEY (user_id) REFERENCES users (user_id)
) ENGINE=InnoDB;

-- Every email the system must send. Procedures INSERT with status 'Queued'; the Node worker sends via
-- Amazon SES and sets Sent / Failed (with retry). Screens show these rows as the
-- "who was told" delivery log — the database never claims "Sent" before the provider confirms.
CREATE TABLE message_outbox (
  message_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type        VARCHAR(40)   NOT NULL,                 -- ewa, rescue, topup, return_request, access_request, soa …
  entity_id          VARCHAR(40)   NOT NULL,
  event_type         VARCHAR(60)   NOT NULL,
  channel            ENUM('Email') NOT NULL DEFAULT 'Email',
  audience           ENUM('Client','Delbros','Applicant','Vendor') NOT NULL,
  recipient_label    VARCHAR(300)  NOT NULL,                 -- role only, no personal data: "Branch Generalist, MNL (schedules the Gate In)"
  recipient_user_id  VARCHAR(100)  NULL,
  recipient_name     VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…)
  to_address         VARCHAR(700)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL, -- PII, AES-256-GCM ciphertext (enc:v1:…) — decrypted only by the sending worker
  subject            VARCHAR(300)  NULL,
  body               TEXT          NULL,
  template_data_json JSON          NULL,
  is_resend          TINYINT(1)    NOT NULL DEFAULT 0,
  status             ENUM('Queued','Sending','Sent','Failed') NOT NULL DEFAULT 'Queued',
  attempts           INT           NOT NULL DEFAULT 0,
  next_attempt_at    DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  provider_message_id VARCHAR(200) NULL,
  last_error         VARCHAR(1000) NULL,
  claim_token        CHAR(36)      NULL,                     -- set by sp_outbox_claim (one worker per message)
  claimed_at         DATETIME(3)   NULL,
  queued_at          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sent_at            DATETIME(3)   NULL,
  PRIMARY KEY (message_id),
  KEY ix_outbox_entity (entity_type, entity_id),
  KEY ix_outbox_queue (status, next_attempt_at),
  KEY ix_outbox_claim (claim_token)
) ENGINE=InnoDB;

-- =====================================================================================================
-- 13. FEEDBACK & AUDIT
-- =====================================================================================================

CREATE TABLE client_feedback (
  feedback_id        VARCHAR(20)   NOT NULL,                 -- FB-00001
  client_code        VARCHAR(20)   NOT NULL,
  category           VARCHAR(60)   NOT NULL,
  topic              VARCHAR(60)   NULL,
  rating             TINYINT       NULL,
  subject            VARCHAR(200)  NOT NULL,
  message            VARCHAR(4000) NOT NULL,
  reference          VARCHAR(60)   NULL,
  status             ENUM('Submitted','Acknowledged','Closed') NOT NULL DEFAULT 'Submitted',
  submitted_at       DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  submitted_by       VARCHAR(100)  NOT NULL,
  PRIMARY KEY (feedback_id),
  KEY ix_fb_client (client_code, submitted_at),
  CONSTRAINT ck_fb_rating CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),
  CONSTRAINT fk_fb_client FOREIGN KEY (client_code) REFERENCES clients (client_code)
) ENGINE=InnoDB;

-- NFR-008: append-only, hash-chained. Written only by sp_audit_write; UPDATE/DELETE blocked by triggers and grants.
CREATE TABLE audit_log (
  audit_id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  event_at           DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  actor              VARCHAR(100)  NOT NULL,
  actor_role         VARCHAR(30)   NOT NULL,
  action             VARCHAR(80)   NOT NULL,
  entity_type        VARCHAR(40)   NOT NULL,
  entity_id          VARCHAR(60)   NOT NULL,
  branch_code        VARCHAR(10)   NULL,
  before_json        JSON          NULL,
  after_json         JSON          NULL,
  reason             VARCHAR(1000) NULL,
  source             VARCHAR(200)  NULL,                     -- 'Portal · 203.0.113.5', 'System job', 'One-click approval link (email)'
  prev_hash          CHAR(64)      NOT NULL,
  row_hash           CHAR(64)      NOT NULL,
  PRIMARY KEY (audit_id),
  KEY ix_audit_entity (entity_type, entity_id),
  KEY ix_audit_actor (actor, event_at)
) ENGINE=InnoDB;

DELIMITER $$
CREATE TRIGGER trg_audit_log_no_update BEFORE UPDATE ON audit_log FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AUDIT_IMMUTABLE: audit_log rows cannot be changed';
END$$
CREATE TRIGGER trg_audit_log_no_delete BEFORE DELETE ON audit_log FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AUDIT_IMMUTABLE: audit_log rows cannot be deleted';
END$$
DELIMITER ;

-- Head of the audit hash chain: one row, locked FOR UPDATE by sp_audit_write so concurrent writers chain in order.
CREATE TABLE audit_chain_head (
  id                 TINYINT       NOT NULL,
  last_audit_id      BIGINT UNSIGNED NOT NULL DEFAULT 0,
  last_hash          CHAR(64)      NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT ck_audit_head_single CHECK (id = 1)
) ENGINE=InnoDB;
INSERT INTO audit_chain_head (id, last_audit_id, last_hash) VALUES (1, 0, REPEAT('0', 64));
