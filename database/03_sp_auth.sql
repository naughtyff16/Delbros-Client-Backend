-- =====================================================================================================
-- 03_sp_auth.sql : sign-in, lockout, email one-time code, session end, password change / reset,
--                  "Request portal access" and the reviewer's one-click approval link
--
-- Split of work with Node (Express auth controller):
--   Node   : verifies password hashes, generates OTP codes / reset & approval tokens, passes only their SHA-256
--            hashes here, sends those secret-bearing emails directly and records them with sp_outbox_record_direct.
--   PDPA   : names, emails, phones and TINs arrive ENCRYPTED (enc:v1:…) with HMAC blind-index hashes for lookups
--            (email_hash, tin_hash). Portal user IDs are generated (U-000001) — never the email address.
--   MySQL  : account states, lockout counters, challenge/attempt rules, token validity, records, audit.
-- =====================================================================================================
USE delbros_portal;

DROP FUNCTION IF EXISTS fn_mask_email;
DROP PROCEDURE IF EXISTS sp_outbox_record_direct;
DROP PROCEDURE IF EXISTS sp_auth_policy;
DROP PROCEDURE IF EXISTS sp_auth_login_lookup;
DROP PROCEDURE IF EXISTS sp_auth_login_failed;
DROP PROCEDURE IF EXISTS sp_auth_access_check;
DROP PROCEDURE IF EXISTS sp_auth_login_success;
DROP PROCEDURE IF EXISTS sp_auth_me;
DROP PROCEDURE IF EXISTS sp_auth_otp_create;
DROP PROCEDURE IF EXISTS sp_auth_otp_verify;
DROP PROCEDURE IF EXISTS sp_auth_otp_resend;
DROP PROCEDURE IF EXISTS sp_auth_session_end;
DROP PROCEDURE IF EXISTS sp_auth_password_hash_get;
DROP PROCEDURE IF EXISTS sp_auth_change_password;
DROP PROCEDURE IF EXISTS sp_auth_reset_request;
DROP PROCEDURE IF EXISTS sp_auth_reset_check;
DROP PROCEDURE IF EXISTS sp_auth_reset_complete;
DROP PROCEDURE IF EXISTS sp_access_request_create;
DROP PROCEDURE IF EXISTS sp_access_request_status;
DROP PROCEDURE IF EXISTS sp_access_approval_get;
DROP PROCEDURE IF EXISTS sp_access_approval_decide;

DELIMITER $$

-- Node sent a secret-bearing email itself (OTP, reset link, approval link) — record it in the delivery log without the secret.
-- p_to / p_recipient_name are ciphertext; p_label is a role ("Account Executive", "Applicant").
CREATE PROCEDURE sp_outbox_record_direct(IN p_entity_type VARCHAR(40), IN p_entity_id VARCHAR(40), IN p_event VARCHAR(60), IN p_audience VARCHAR(10),
  IN p_label VARCHAR(300), IN p_recipient_name VARCHAR(700), IN p_to VARCHAR(700), IN p_subject VARCHAR(300), IN p_status VARCHAR(10), IN p_provider_id VARCHAR(200), IN p_error VARCHAR(1000))
BEGIN
  INSERT INTO message_outbox (entity_type, entity_id, event_type, channel, audience, recipient_label, recipient_name, to_address, subject, status, attempts, provider_message_id, last_error, sent_at)
  VALUES (p_entity_type, p_entity_id, p_event, 'Email', p_audience, p_label, p_recipient_name, p_to, p_subject, p_status, 1, p_provider_id, p_error, IF(p_status = 'Sent', UTC_TIMESTAMP(3), NULL));
END$$

-- GET /auth/policy — public sign-in policy (no personal data). Node overlays releaseContacts from config.
CREATE PROCEDURE sp_auth_policy()
BEGIN
  SELECT CAST(fn_setting_num('auth.max_failed_logins', 5) AS UNSIGNED)                 AS maxFailed,
         CAST(fn_setting_num('auth.lockout_minutes', 30) AS UNSIGNED)                  AS lockoutMinutes,
         CAST(fn_setting_num('auth.password_min_length', 10) AS UNSIGNED)              AS passwordMinLength,
         CAST(fn_setting_num('auth.portal_session_timeout_minutes', 15) AS UNSIGNED)   AS sessionTimeoutMinutes,
         IF(fn_setting_text('auth.portal_second_factor', 'email_otp') = 'off', 'off', 'email_otp') AS secondFactor,
         CAST(fn_setting_num('auth.otp_minutes', 5) AS UNSIGNED)                       AS otpMinutes,
         CAST(fn_setting_num('auth.otp_resend_seconds', 30) AS UNSIGNED)               AS otpResendSeconds,
         CAST(fn_setting_num('auth.reset_link_minutes', 30) AS UNSIGNED)               AS resetLinkMinutes,
         fn_setting_text('portal.registration_extras', 'tin,documents,consent')        AS registrationExtras,
         fn_setting_text('portal.client_support_phone', '')                            AS clientSupportPhone,
         fn_setting_text('portal.client_support_email', '')                            AS clientSupportEmail,
         fn_setting_text('portal.vendor_support_phone', '')                            AS vendorSupportPhone,
         fn_setting_text('portal.vendor_support_email', '')                            AS vendorSupportEmail,
         fn_setting_text('portal.dpo_email', '')                                       AS dpoEmail;
END$$

-- POST /auth/login step 1, by email blind index. RS1 = the user in the chosen portal; RS2 (only when RS1 is empty) = same email
-- in the other portal, so Node can say WRONG_PORTAL after verifying the password against it.
CREATE PROCEDURE sp_auth_login_lookup(IN p_email_hash CHAR(64), IN p_realm VARCHAR(20))
BEGIN
  SELECT user_id AS userId, realm, password_hash AS passwordHash, status, failed_logins AS failedLogins, locked_until AS lockedUntil,
         (locked_until IS NOT NULL AND locked_until > UTC_TIMESTAMP(3)) AS isLocked
    FROM users WHERE email_hash = p_email_hash AND realm = p_realm AND realm <> 'INTERNAL';
  SELECT user_id AS userId, realm, password_hash AS passwordHash
    FROM users WHERE email_hash = p_email_hash AND realm <> p_realm AND realm <> 'INTERNAL'
     AND NOT EXISTS (SELECT 1 FROM users x WHERE x.email_hash = p_email_hash AND x.realm = p_realm);
END$$

-- Wrong password for an existing user: count it; lock after auth.max_failed_logins for auth.lockout_minutes.
CREATE PROCEDURE sp_auth_login_failed(IN p_user_id VARCHAR(100), IN p_source VARCHAR(200),
  OUT o_failed INT, OUT o_locked_until DATETIME(3), OUT o_max INT, OUT o_lockout_minutes INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_max = fn_setting_num('auth.max_failed_logins', 5), o_lockout_minutes = fn_setting_num('auth.lockout_minutes', 30), o_locked_until = NULL;
  START TRANSACTION;
  UPDATE users SET failed_logins = failed_logins + 1 WHERE user_id = p_user_id;
  SELECT failed_logins INTO o_failed FROM users WHERE user_id = p_user_id;
  CALL sp_audit_write(p_user_id, fn_user_role(p_user_id), 'auth.login_failed', 'user', p_user_id, NULL, NULL, JSON_OBJECT('failedAttempts', o_failed), NULL, p_source);
  IF o_failed >= o_max THEN
    SET o_locked_until = UTC_TIMESTAMP(3) + INTERVAL o_lockout_minutes MINUTE;
    UPDATE users SET locked_until = o_locked_until WHERE user_id = p_user_id;
    CALL sp_audit_write(p_user_id, fn_user_role(p_user_id), 'auth.account_locked', 'user', p_user_id, NULL, NULL,
         JSON_OBJECT('failedAttempts', o_failed, 'lockedUntil', o_locked_until), CONCAT('Locked after ', o_failed, ' failed sign-in attempts'), p_source);
  END IF;
  COMMIT;
END$$

-- Account state, checked only after the password is correct. A hold is NOT refused here — it is shown after sign-in (BR-01).
-- o_contact = who to call (Account Executive fields are ciphertext; Node decrypts).
CREATE PROCEDURE sp_auth_access_check(IN p_user_id VARCHAR(100), IN p_source VARCHAR(200),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_contact JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_ustatus VARCHAR(10); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20);
  DECLARE v_cstatus VARCHAR(20); DECLARE v_cname VARCHAR(200); DECLARE v_src VARCHAR(10); DECLARE v_acc VARCHAR(30);
  DECLARE v_vstatus VARCHAR(10); DECLARE v_vname VARCHAR(200);
  SET o_err_code = NULL, o_err_msg = NULL, o_contact = NULL;
  SELECT realm, status, client_code, vendor_id INTO v_realm, v_ustatus, v_client, v_vendor FROM users WHERE user_id = p_user_id;
  IF v_realm = 'CLIENT_PORTAL' THEN
    SELECT c.status, c.client_name, c.registration_source,
           JSON_OBJECT('role', 'Your Account Executive', 'name', a.full_name, 'phone', a.mobile, 'email', a.email)
      INTO v_cstatus, v_cname, v_src, o_contact
      FROM clients c LEFT JOIN users a ON a.user_id = c.ae_user_id WHERE c.client_code = v_client;
    IF v_ustatus <> 'Active' AND v_cstatus = 'Draft' AND v_src = 'Portal' THEN
      SET o_err_code = 'ACCOUNT_PENDING', o_err_msg = CONCAT('Your request for portal access for ', v_cname, ' is still being reviewed by your Account Executive. We will email you as soon as access is approved.');
    ELSEIF v_ustatus <> 'Active' THEN
      SET o_err_code = 'ACCOUNT_INACTIVE', o_err_msg = 'This portal user has been deactivated. Ask your Account Executive to reactivate it or to add a new user for your company.';
    ELSEIF v_cstatus IS NULL THEN
      SET o_err_code = 'ACCOUNT_INACTIVE', o_err_msg = 'No active company account is linked to this user. Please contact Delbros Client Support.';
    ELSEIF v_cstatus = 'Draft' THEN
      SELECT MAX(status) INTO v_acc FROM accreditations WHERE client_code = v_client AND status LIKE 'Pending%';
      SET o_err_code = 'NOT_ACCREDITED', o_err_msg = CONCAT(v_cname, ' is not yet accredited',
          IF(v_acc IS NULL, '', CONCAT(' — the application is at ', REPLACE(REPLACE(v_acc, 'Pending ', ''), 'C&C', 'Credit & Collection'), ' review')),
          '. Portal sign-in opens once accreditation is approved.');
    ELSEIF v_cstatus = 'Inactive' THEN
      SET o_err_code = 'ACCOUNT_INACTIVE', o_err_msg = CONCAT('The ', v_cname, ' account is inactive (no active contract). Your Account Executive can reactivate it.');
    ELSEIF v_cstatus = 'Blacklist' THEN
      SET o_err_code = 'ACCOUNT_INACTIVE', o_err_msg = CONCAT('Portal access for ', v_cname, ' is suspended. Please contact your Account Executive.');
    END IF;
  ELSEIF v_realm = 'VENDOR_PORTAL' THEN
    SET o_contact = JSON_OBJECT('role', 'Delbros Procurement', 'phone', fn_setting_text('portal.vendor_support_phone', ''), 'email', fn_setting_text('portal.vendor_support_email', ''));
    SELECT status, vendor_name INTO v_vstatus, v_vname FROM vendors WHERE vendor_id = v_vendor;
    IF v_ustatus <> 'Active' AND v_vstatus = 'Pending' THEN
      SET o_err_code = 'ACCOUNT_PENDING', o_err_msg = CONCAT('Your request for vendor portal access for ', v_vname, ' is still being reviewed by Delbros Procurement. We will email you as soon as access is approved.');
    ELSEIF v_ustatus <> 'Active' THEN
      SET o_err_code = 'ACCOUNT_INACTIVE', o_err_msg = 'This vendor portal user has been deactivated. Please contact Delbros Procurement.';
    ELSEIF v_vstatus IS NULL THEN
      SET o_err_code = 'ACCOUNT_INACTIVE', o_err_msg = 'No active supplier account is linked to this user. Please contact Delbros Procurement.';
    ELSEIF v_vstatus = 'Pending' THEN
      SET o_err_code = 'NOT_ACCREDITED', o_err_msg = CONCAT(v_vname, ' is not yet an accredited Delbros supplier. Portal sign-in opens once Procurement completes vendor accreditation.');
    ELSEIF v_vstatus <> 'Active' THEN
      SET o_err_code = 'ACCOUNT_INACTIVE', o_err_msg = CONCAT('The ', v_vname, ' supplier account is ', LOWER(v_vstatus), '. Please contact Delbros Procurement.');
    END IF;
  ELSE
    SET o_err_code = 'INVALID_CREDENTIALS', o_err_msg = 'The email or password is incorrect.';
  END IF;
  IF o_err_code IS NOT NULL THEN
    CALL sp_audit_write(p_user_id, fn_user_role(p_user_id), 'auth.login_refused', 'user', p_user_id, NULL, NULL, JSON_OBJECT('reason', o_err_code), NULL, p_source);
  END IF;
END$$

-- Profile of the signed-in user (GET /auth/me, also returned by login). name / email / mobile are ciphertext.
CREATE PROCEDURE sp_auth_me(IN p_user_id VARCHAR(100))
BEGIN
  SELECT u.user_id AS userId, u.full_name AS name, u.email, u.mobile, u.designation, u.status, u.realm, u.client_code AS clientCode, u.vendor_id AS vendorId,
         u.branch_code AS branchCode, u.last_login_at AS lastLogin, u.must_change_password AS mustChangePassword,
         (SELECT JSON_ARRAYAGG(role_code) FROM user_roles r WHERE r.user_id = u.user_id) AS roles,
         c.client_name AS clientName, c.status AS clientStatus, v.vendor_name AS vendorName,
         IFNULL(cb.billing_entity, 'DBL') AS billingEntity   -- pay-to entity of the client's home branch (Nakamura for Mindanao)
    FROM users u LEFT JOIN clients c ON c.client_code = u.client_code LEFT JOIN vendors v ON v.vendor_id = u.vendor_id
    LEFT JOIN branches cb ON cb.branch_code = c.branch_code
   WHERE u.user_id = p_user_id;
END$$

CREATE PROCEDURE sp_auth_login_success(IN p_user_id VARCHAR(100), IN p_second_factor VARCHAR(20), IN p_source VARCHAR(200))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  UPDATE users SET failed_logins = 0, locked_until = NULL, last_login_at = UTC_TIMESTAMP(3) WHERE user_id = p_user_id;
  CALL sp_audit_write(p_user_id, fn_user_role(p_user_id), 'auth.login', 'user', p_user_id, NULL, NULL,
       JSON_OBJECT('realm', (SELECT realm FROM users WHERE user_id = p_user_id), 'secondFactor', p_second_factor), NULL, p_source);
  COMMIT;
  CALL sp_auth_me(p_user_id);
END$$

-- Second factor: a new challenge replaces any open one. o_email (ciphertext) → Node decrypts, sends the code and masks the address.
CREATE PROCEDURE sp_auth_otp_create(IN p_user_id VARCHAR(100), IN p_challenge_id CHAR(48), IN p_code_hash CHAR(64), IN p_source VARCHAR(200),
  OUT o_expires_at DATETIME(3), OUT o_resend_after DATETIME(3), OUT o_email VARCHAR(700))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_expires_at = UTC_TIMESTAMP(3) + INTERVAL fn_setting_num('auth.otp_minutes', 5) MINUTE;
  SET o_resend_after = UTC_TIMESTAMP(3) + INTERVAL fn_setting_num('auth.otp_resend_seconds', 30) SECOND;
  SELECT email INTO o_email FROM users WHERE user_id = p_user_id;
  START TRANSACTION;
  DELETE FROM auth_otp_challenges WHERE user_id = p_user_id AND consumed_at IS NULL;
  INSERT INTO auth_otp_challenges (challenge_id, user_id, code_hash, expires_at, resend_after) VALUES (p_challenge_id, p_user_id, p_code_hash, o_expires_at, o_resend_after);
  CALL sp_audit_write(p_user_id, fn_user_role(p_user_id), 'auth.otp_sent', 'user', p_user_id, NULL, NULL, JSON_OBJECT('channel', 'Email'), NULL, p_source);
  COMMIT;
END$$

-- POST /auth/otp/verify. On success completes the sign-in and returns the profile (sp_auth_me result set).
CREATE PROCEDURE sp_auth_otp_verify(IN p_challenge_id CHAR(48), IN p_code_hash CHAR(64), IN p_source VARCHAR(200),
  OUT o_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_hash CHAR(64); DECLARE v_exp DATETIME(3); DECLARE v_att INT; DECLARE v_max INT DEFAULT fn_setting_num('auth.otp_max_attempts', 5);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL, o_user_id = NULL;
  START TRANSACTION;
  SELECT user_id, code_hash, expires_at, attempts INTO o_user_id, v_hash, v_exp, v_att
    FROM auth_otp_challenges WHERE challenge_id = p_challenge_id AND consumed_at IS NULL FOR UPDATE;
  IF o_user_id IS NULL THEN
    ROLLBACK; SET o_err_code = 'OTP_EXPIRED', o_err_msg = 'This sign-in code is no longer valid. Sign in again to get a new code.'; LEAVE proc;
  END IF;
  IF v_exp < UTC_TIMESTAMP(3) THEN
    DELETE FROM auth_otp_challenges WHERE challenge_id = p_challenge_id; COMMIT;
    SET o_err_code = 'OTP_EXPIRED', o_err_msg = CONCAT('The code expired (codes are valid for ', CAST(fn_setting_num('auth.otp_minutes', 5) AS UNSIGNED), ' minutes). Sign in again to get a new code.'); LEAVE proc;
  END IF;
  IF v_hash <> p_code_hash THEN
    SET v_att = v_att + 1;
    CALL sp_audit_write(o_user_id, fn_user_role(o_user_id), 'auth.otp_failed', 'user', o_user_id, NULL, NULL, JSON_OBJECT('attempts', v_att), NULL, p_source);
    IF v_att >= v_max THEN
      DELETE FROM auth_otp_challenges WHERE challenge_id = p_challenge_id; COMMIT;
      SET o_err_code = 'OTP_LOCKED', o_err_msg = 'Too many incorrect codes. Sign in again to get a new code.'; LEAVE proc;
    END IF;
    UPDATE auth_otp_challenges SET attempts = v_att WHERE challenge_id = p_challenge_id; COMMIT;
    SET o_err_code = 'OTP_INVALID', o_err_msg = CONCAT('That code is incorrect. ', v_max - v_att, IF(v_max - v_att = 1, ' attempt', ' attempts'), ' left.'),
        o_err_fields = JSON_OBJECT('code', 'Incorrect code');
    LEAVE proc;
  END IF;
  UPDATE auth_otp_challenges SET consumed_at = UTC_TIMESTAMP(3) WHERE challenge_id = p_challenge_id;
  COMMIT;
  CALL sp_auth_login_success(o_user_id, 'Email OTP', p_source);
END$$

CREATE PROCEDURE sp_auth_otp_resend(IN p_challenge_id CHAR(48), IN p_new_code_hash CHAR(64), IN p_source VARCHAR(200),
  OUT o_email VARCHAR(700), OUT o_expires_at DATETIME(3), OUT o_resend_after_seconds INT, OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_user VARCHAR(100); DECLARE v_exp DATETIME(3); DECLARE v_resend DATETIME(3);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_resend_after_seconds = fn_setting_num('auth.otp_resend_seconds', 30);
  START TRANSACTION;
  SELECT user_id, expires_at, resend_after INTO v_user, v_exp, v_resend FROM auth_otp_challenges WHERE challenge_id = p_challenge_id AND consumed_at IS NULL FOR UPDATE;
  IF v_user IS NULL OR v_exp < UTC_TIMESTAMP(3) THEN
    ROLLBACK; SET o_err_code = 'OTP_EXPIRED', o_err_msg = 'This sign-in code is no longer valid. Sign in again to get a new code.'; LEAVE proc;
  END IF;
  IF v_resend > UTC_TIMESTAMP(3) THEN
    ROLLBACK; SET o_err_code = 'OTP_WAIT', o_err_msg = CONCAT('You can request a new code in ', CEIL(TIMESTAMPDIFF(MICROSECOND, UTC_TIMESTAMP(3), v_resend) / 1000000), ' seconds.'); LEAVE proc;
  END IF;
  SET o_expires_at = UTC_TIMESTAMP(3) + INTERVAL fn_setting_num('auth.otp_minutes', 5) MINUTE;
  UPDATE auth_otp_challenges SET code_hash = p_new_code_hash, expires_at = o_expires_at, attempts = 0,
         resend_after = UTC_TIMESTAMP(3) + INTERVAL o_resend_after_seconds SECOND WHERE challenge_id = p_challenge_id;
  SELECT email INTO o_email FROM users WHERE user_id = v_user;
  CALL sp_audit_write(v_user, fn_user_role(v_user), 'auth.otp_sent', 'user', v_user, NULL, NULL, JSON_OBJECT('channel', 'Email', 'resend', TRUE), NULL, p_source);
  COMMIT;
END$$

-- POST /auth/logout and the idle-timeout expiry (p_reason 'signed_out' | 'idle').
CREATE PROCEDURE sp_auth_session_end(IN p_user_id VARCHAR(100), IN p_reason VARCHAR(20), IN p_idle_minutes INT, IN p_source VARCHAR(200))
BEGIN
  CALL sp_audit_write(p_user_id, fn_user_role(p_user_id), IF(p_reason = 'idle', 'auth.session_expired', 'auth.logout'), 'user', p_user_id, NULL, NULL,
       IF(p_reason = 'idle', JSON_OBJECT('idleMinutes', p_idle_minutes), NULL), NULL, p_source);
END$$

CREATE PROCEDURE sp_auth_password_hash_get(IN p_user_id VARCHAR(100))
BEGIN
  SELECT password_hash AS passwordHash FROM users WHERE user_id = p_user_id;
END$$

-- POST /auth/change-password (Node has verified the current password and the strength rules).
CREATE PROCEDURE sp_auth_change_password(IN p_user_id VARCHAR(100), IN p_new_hash VARCHAR(255), IN p_source VARCHAR(200))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  UPDATE users SET password_hash = p_new_hash, password_changed_at = UTC_TIMESTAMP(3), must_change_password = 0, row_version = row_version + 1 WHERE user_id = p_user_id;
  CALL sp_audit_write(p_user_id, fn_user_role(p_user_id), 'auth.password_changed', 'user', p_user_id, NULL, NULL, NULL, NULL, p_source);
  COMMIT;
END$$

-- POST /auth/forgot-password (by email blind index). Always answers the same way to the browser; o_user_found tells Node
-- whether to send the reset email to o_email (ciphertext). A new link replaces older unused ones.
CREATE PROCEDURE sp_auth_reset_request(IN p_email_hash CHAR(64), IN p_token_hash CHAR(64), IN p_source VARCHAR(200),
  OUT o_user_found TINYINT, OUT o_user_id VARCHAR(100), OUT o_name VARCHAR(700), OUT o_email VARCHAR(700), OUT o_expires_at DATETIME(3))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_user_found = 0, o_user_id = NULL, o_name = NULL, o_email = NULL, o_expires_at = NULL;
  SELECT MAX(user_id), MAX(full_name), MAX(email) INTO o_user_id, o_name, o_email FROM users WHERE email_hash = p_email_hash AND realm <> 'INTERNAL';
  IF o_user_id IS NOT NULL THEN
    SET o_user_found = 1, o_expires_at = UTC_TIMESTAMP(3) + INTERVAL fn_setting_num('auth.reset_link_minutes', 30) MINUTE;
    START TRANSACTION;
    DELETE FROM auth_password_resets WHERE user_id = o_user_id AND used_at IS NULL;
    INSERT INTO auth_password_resets (token_hash, user_id, expires_at) VALUES (p_token_hash, o_user_id, o_expires_at);
    CALL sp_audit_write(o_user_id, fn_user_role(o_user_id), 'auth.password_reset_requested', 'user', o_user_id, NULL, NULL, JSON_OBJECT('channel', 'Email'), NULL, p_source);
    COMMIT;
  END IF;
END$$

-- GET /auth/reset-password/:token
CREATE PROCEDURE sp_auth_reset_check(IN p_token_hash CHAR(64), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_user VARCHAR(100); DECLARE v_exp DATETIME(3); DECLARE v_used DATETIME(3);
  SET o_err_code = NULL, o_err_msg = NULL;
  SELECT MAX(user_id), MAX(expires_at), MAX(used_at) INTO v_user, v_exp, v_used FROM auth_password_resets WHERE token_hash = p_token_hash;
  IF v_user IS NULL THEN SET o_err_code = 'RESET_INVALID', o_err_msg = 'This reset link is not valid. Request a new link from Forgot password.'; LEAVE proc; END IF;
  IF v_used IS NOT NULL THEN SET o_err_code = 'RESET_USED', o_err_msg = 'This reset link has already been used. If you did not change your password, request a new link.'; LEAVE proc; END IF;
  IF v_exp < UTC_TIMESTAMP(3) THEN SET o_err_code = 'RESET_EXPIRED', o_err_msg = 'This reset link has expired. Request a new link from Forgot password.'; LEAVE proc; END IF;
  SELECT u.user_id AS userId, u.email, u.realm, v_exp AS expiresAt, CAST(fn_setting_num('auth.password_min_length', 10) AS UNSIGNED) AS minLength, u.password_hash AS currentHash
    FROM users u WHERE u.user_id = v_user;
END$$

-- POST /auth/reset-password. A successful reset also unlocks the account; the link becomes single-use.
CREATE PROCEDURE sp_auth_reset_complete(IN p_token_hash CHAR(64), IN p_new_hash VARCHAR(255), IN p_source VARCHAR(200),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_user VARCHAR(100); DECLARE v_exp DATETIME(3); DECLARE v_used DATETIME(3); DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL;
  START TRANSACTION;
  SELECT reset_id, user_id, expires_at, used_at INTO v_id, v_user, v_exp, v_used FROM auth_password_resets WHERE token_hash = p_token_hash FOR UPDATE;
  IF v_user IS NULL OR v_used IS NOT NULL OR v_exp < UTC_TIMESTAMP(3) THEN
    ROLLBACK; SET o_err_code = IF(v_user IS NULL, 'RESET_INVALID', IF(v_used IS NOT NULL, 'RESET_USED', 'RESET_EXPIRED')),
                  o_err_msg = 'This reset link can no longer be used. Request a new link from Forgot password.'; LEAVE proc;
  END IF;
  UPDATE users SET password_hash = p_new_hash, password_changed_at = UTC_TIMESTAMP(3), failed_logins = 0, locked_until = NULL, row_version = row_version + 1 WHERE user_id = v_user;
  UPDATE auth_password_resets SET used_at = UTC_TIMESTAMP(3) WHERE reset_id = v_id;
  DELETE FROM auth_password_resets WHERE user_id = v_user AND reset_id <> v_id;
  CALL sp_audit_write(v_user, fn_user_role(v_user), 'auth.password_reset', 'user', v_user, NULL, NULL, JSON_OBJECT('via', 'Email link', 'unlocked', TRUE), NULL, p_source);
  COMMIT;
END$$

-- ── Request portal access (client or vendor) ─────────────────────────────────────────────────────────
-- Node has validated the form, uploaded the documents (files with purpose ACCESS_DOC), hashed the password, and ENCRYPTED
-- first/last/full name, email, phone and TIN (+ email_hash, tin_hash). p_documents = JSON array of file_id.
-- Outputs o_reviewer_email / o_reviewer_name (ciphertext, or the plain Procurement address from settings) so Node can
-- email the reviewer the one-click link; the token itself is known only to Node.
CREATE PROCEDURE sp_access_request_create(
  IN p_account_type VARCHAR(10), IN p_company_name VARCHAR(200), IN p_tin VARCHAR(700), IN p_tin_hash CHAR(64), IN p_branch_code VARCHAR(10), IN p_address VARCHAR(255),
  IN p_first_name VARCHAR(700), IN p_last_name VARCHAR(700), IN p_full_name VARCHAR(700), IN p_email VARCHAR(700), IN p_email_hash CHAR(64), IN p_phone VARCHAR(700),
  IN p_password_hash VARCHAR(255), IN p_documents JSON, IN p_consent TINYINT, IN p_approval_token_hash CHAR(64), IN p_source VARCHAR(200),
  OUT o_reference VARCHAR(20), OUT o_subject_id VARCHAR(20), OUT o_user_id VARCHAR(20), OUT o_reviewer_label VARCHAR(150), OUT o_reviewer_name VARCHAR(700), OUT o_reviewer_email VARCHAR(700),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_vendor TINYINT DEFAULT (p_account_type = 'vendor');
  DECLARE v_ae VARCHAR(100); DECLARE v_reviewer_user VARCHAR(100);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;

  IF p_email_hash IS NULL OR IFNULL(p_email, '') NOT LIKE 'enc:%' OR IFNULL(p_full_name, '') NOT LIKE 'enc:%' THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.', o_err_fields = JSON_OBJECT('email', 'Not encrypted by the backend'); LEAVE proc;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM branches WHERE branch_code = p_branch_code AND is_active = 1) THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.', o_err_fields = JSON_OBJECT('branchCode', 'Choose a branch'); LEAVE proc;
  END IF;
  -- One email = one company (blind-index comparisons)
  IF EXISTS (SELECT 1 FROM users WHERE email_hash = p_email_hash) THEN
    SET o_err_code = 'EMAIL_IN_USE', o_err_msg = 'This email already has an account. One email can belong to only one company — sign in, or use Forgot password.',
        o_err_fields = JSON_OBJECT('email', 'Already registered — one email can belong to only one company'); LEAVE proc;
  END IF;
  IF EXISTS (SELECT 1 FROM client_contacts WHERE email_hash = p_email_hash AND is_active = 1) THEN
    SET o_err_code = 'EMAIL_OTHER_COMPANY', o_err_msg = 'This email is already on file for an existing Delbros client. One email can belong to only one company — ask that company’s Account Executive to add you as a portal user, or use a different email.',
        o_err_fields = JSON_OBJECT('email', 'Already on file for another company'); LEAVE proc;
  END IF;
  IF EXISTS (SELECT 1 FROM vendors WHERE email_hash = p_email_hash) THEN
    SET o_err_code = 'EMAIL_OTHER_COMPANY', o_err_msg = 'This email is already on file for an existing Delbros supplier. One email can belong to only one company — contact Delbros Procurement, or use a different email.',
        o_err_fields = JSON_OBJECT('email', 'Already on file for another company'); LEAVE proc;
  END IF;
  -- One TIN = one company (blind index of the first 9 digits)
  IF p_tin_hash IS NOT NULL AND v_vendor = 0 AND (EXISTS (SELECT 1 FROM clients WHERE tin_hash = p_tin_hash) OR EXISTS (SELECT 1 FROM accreditations WHERE tin_hash = p_tin_hash)) THEN
    SET o_err_code = 'TIN_IN_USE', o_err_msg = 'A client with this TIN is already registered. Ask your Account Executive to add you as a portal user instead of submitting a new request.',
        o_err_fields = JSON_OBJECT('tin', 'A client with this TIN is already registered'); LEAVE proc;
  END IF;
  IF p_tin_hash IS NOT NULL AND v_vendor = 1 AND EXISTS (SELECT 1 FROM vendors WHERE tin_hash = p_tin_hash) THEN
    SET o_err_code = 'TIN_IN_USE', o_err_msg = 'A supplier with this TIN is already registered. Please contact Delbros Procurement.',
        o_err_fields = JSON_OBJECT('tin', 'A supplier with this TIN is already registered'); LEAVE proc;
  END IF;

  START TRANSACTION;
  CALL sp_next_number('USER', 'U-', 6, o_user_id);
  IF v_vendor = 1 THEN
    CALL sp_next_number('VENDOR', 'V-', 3, o_subject_id);
    INSERT INTO vendors (vendor_id, vendor_name, tin, tin_hash, address, email, email_hash, phone, contact_person, status, portal_access)
    VALUES (o_subject_id, TRIM(p_company_name), p_tin, p_tin_hash, TRIM(p_address), p_email, p_email_hash, p_phone, p_full_name, 'Pending', 0);
    INSERT INTO users (user_id, realm, full_name, designation, email, email_hash, mobile, status, branch_code, vendor_id, password_hash)
    VALUES (o_user_id, 'VENDOR_PORTAL', p_full_name, CONCAT('Vendor — ', TRIM(p_company_name)), p_email, p_email_hash, p_phone, 'Inactive', p_branch_code, o_subject_id, p_password_hash);
    INSERT INTO user_roles (user_id, role_code) VALUES (o_user_id, 'VENDOR');
    SET o_reviewer_label = 'Delbros Procurement', o_reviewer_name = NULL, o_reviewer_email = NULLIF(fn_setting_text('portal.vendor_support_email', ''), '');
    CALL sp_notify_roles(JSON_ARRAY('APS_OFFICER','APS_MANAGER'), NULL, 'vendor.portal_registered', CONCAT('New vendor portal request: ', TRIM(p_company_name)),
         CONCAT(JSON_LENGTH(IFNULL(p_documents, JSON_ARRAY())), ' document(s) — review and accredit the supplier.'), '/procurement/vendors');
  ELSE
    CALL sp_next_number('CLIENT', 'C-', 5, o_subject_id);
    -- Account Executive: the branch default (setting portal.default_ae.<branch>) or the global default.
    SET v_ae = NULLIF(fn_setting_text(CONCAT('portal.default_ae.', p_branch_code), fn_setting_text('portal.default_ae', '')), '');
    INSERT INTO clients (client_code, client_name, billing_name, tin, tin_hash, address1, country, billing_cycle, ae_user_id, branch_code, status, registration_source)
    VALUES (o_subject_id, TRIM(p_company_name), TRIM(p_company_name), p_tin, p_tin_hash, TRIM(p_address), 'PHILIPPINES', 'Weekly', v_ae, p_branch_code, 'Draft', 'Portal');
    INSERT INTO client_contacts (client_code, first_name, last_name, phone, email, email_hash, is_primary) VALUES (o_subject_id, p_first_name, p_last_name, p_phone, p_email, p_email_hash, 1);
    INSERT INTO client_branch_access (client_code, branch_code) VALUES (o_subject_id, p_branch_code);
    INSERT INTO users (user_id, realm, full_name, designation, email, email_hash, mobile, status, branch_code, client_code, password_hash)
    VALUES (o_user_id, 'CLIENT_PORTAL', p_full_name, CONCAT('Client — ', TRIM(p_company_name)), p_email, p_email_hash, p_phone, 'Inactive', p_branch_code, o_subject_id, p_password_hash);
    INSERT INTO user_roles (user_id, role_code) VALUES (o_user_id, 'CLIENT');
    SELECT MAX(user_id), MAX(full_name), MAX(email) INTO v_reviewer_user, o_reviewer_name, o_reviewer_email FROM users WHERE user_id = v_ae;
    SET o_reviewer_label = 'Your Account Executive';
    CALL sp_notify_user(v_ae, 'client.portal_registered', CONCAT('New portal registration: ', TRIM(p_company_name)),
         CONCAT(JSON_LENGTH(IFNULL(p_documents, JSON_ARRAY())), ' document(s). Approve or deny from the one-click link in your email.'), '/clients');
  END IF;

  CALL sp_next_number('PAR', 'PAR-', 6, o_reference);
  INSERT INTO portal_access_requests (reference, account_type, subject_id, company_name, tin, tin_hash, branch_code, address, contact_name, email, email_hash, phone, privacy_consent_at,
         status, reviewer_label, reviewer_user_id, applicant_user_id, approval_token_hash, approval_expires_at)
  VALUES (o_reference, p_account_type, o_subject_id, TRIM(p_company_name), p_tin, p_tin_hash, p_branch_code, TRIM(p_address), p_full_name, p_email, p_email_hash, p_phone,
          IF(p_consent = 1, UTC_TIMESTAMP(3), NULL), 'Submitted', o_reviewer_label, v_reviewer_user, o_user_id, p_approval_token_hash,
          UTC_TIMESTAMP(3) + INTERVAL fn_setting_num('portal.access_link_days', 7) DAY);
  UPDATE files f JOIN JSON_TABLE(IFNULL(p_documents, JSON_ARRAY()), '$[*]' COLUMNS (fid CHAR(36) PATH '$')) d ON d.fid = f.file_id
     SET f.entity_type = 'access_request', f.entity_id = o_reference, f.owner_client_code = IF(v_vendor = 0, o_subject_id, NULL), f.owner_vendor_id = IF(v_vendor = 1, o_subject_id, NULL)
   WHERE f.purpose = 'ACCESS_DOC' AND f.entity_id IS NULL;
  CALL sp_outbox_queue('access_request', o_reference, 'access.acknowledged', 'Email', 'Applicant', 'Applicant', p_email,
       CONCAT('We received your portal access request — ', o_reference), NULL, JSON_OBJECT('reference', o_reference, 'company', TRIM(p_company_name)), 0, p_full_name);
  CALL sp_audit_write(o_user_id, IF(v_vendor = 1, 'VENDOR', 'CLIENT'), IF(v_vendor = 1, 'vendor.portal_registered', 'client.portal_registered'),
       IF(v_vendor = 1, 'vendor', 'client'), o_subject_id, p_branch_code, NULL,
       JSON_OBJECT('reference', o_reference, 'companyName', TRIM(p_company_name), 'documents', p_documents), NULL, p_source);
  COMMIT;
END$$

-- GET /access-requests/status?reference=&email= — Node passes the email blind index; both must match.
CREATE PROCEDURE sp_access_request_status(IN p_reference VARCHAR(20), IN p_email_hash CHAR(64), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  SET o_err_code = NULL, o_err_msg = NULL;
  IF NOT EXISTS (SELECT 1 FROM portal_access_requests WHERE reference = UPPER(TRIM(p_reference)) AND email_hash = p_email_hash) THEN
    SET o_err_code = 'NOT_FOUND', o_err_msg = 'No request matches this reference and email. Check both and try again.'; LEAVE proc;
  END IF;
  SELECT r.reference, r.account_type AS accountType, r.company_name AS companyName, r.submitted_at AS submittedAt, r.status,
         CASE r.status WHEN 'Approved' THEN 'Approved' WHEN 'Rejected' THEN 'Denied'
              ELSE IF(r.account_type = 'vendor', 'Pending Procurement approval', 'Pending AE approval') END AS statusLabel,
         r.reviewer_label AS reviewer, (SELECT full_name FROM users WHERE user_id = r.reviewer_user_id) AS reviewerName,
         IF(r.status = 'Approved' AND r.account_type = 'client', r.subject_id, NULL) AS companyCode,
         IF(r.status = 'Approved', r.billing_name, NULL) AS billingName,
         IF(r.status = 'Rejected', r.decision_reason, NULL) AS reason, r.decided_at AS decidedAt,
         EXISTS (SELECT 1 FROM message_outbox m WHERE m.entity_type = 'access_request' AND m.entity_id = r.reference AND m.audience <> 'Applicant' AND m.status <> 'Failed') AS reviewerNotified,
         CASE WHEN r.status = 'Approved' THEN IF(r.account_type = 'vendor', 'Procurement completes your supplier accreditation; you can then sign in.',
                                                 'Accreditation (Credit & Collection → Finance → Vice President). You can sign in and will see the accreditation status.')
              WHEN r.status = 'Rejected' THEN 'You may submit a new request with the corrected details.'
              ELSE CONCAT('Waiting for ', r.reviewer_label, ' to approve. You will be emailed the decision.') END AS nextStep
    FROM portal_access_requests r WHERE r.reference = UPPER(TRIM(p_reference));
  SELECT queued_at AS at, audience, channel, to_address AS `to`, subject, status FROM message_outbox
   WHERE entity_type = 'access_request' AND entity_id = UPPER(TRIM(p_reference)) AND audience = 'Applicant' ORDER BY queued_at;
END$$

-- GET /access-approval/:token — the reviewer opens the emailed link (still readable after the decision).
CREATE PROCEDURE sp_access_approval_get(IN p_token_hash CHAR(64), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  SET o_err_code = NULL, o_err_msg = NULL;
  IF NOT EXISTS (SELECT 1 FROM portal_access_requests WHERE approval_token_hash = p_token_hash) THEN
    SET o_err_code = 'APPROVAL_LINK_INVALID', o_err_msg = 'This approval link is not valid. It may be incomplete — open it from the email again.'; LEAVE proc;
  END IF;
  SELECT r.reference, r.account_type AS accountType, r.company_name AS companyName, r.tin, r.branch_code AS branchCode, r.address, r.contact_name AS contactName,
         r.email, r.phone, r.submitted_at AS submittedAt, r.status, r.reviewer_label AS reviewer,
         IF(r.account_type = 'client', r.subject_id, NULL) AS companyCode, IFNULL(r.billing_name, r.company_name) AS billingName,
         r.approval_expires_at AS expiresAt, (r.status = 'Submitted' AND r.approval_expires_at < UTC_TIMESTAMP(3)) AS expired,
         r.decided_at AS decidedAt, IFNULL((SELECT full_name FROM users WHERE user_id = r.decided_by), r.decided_by) AS decidedBy, r.decision_reason AS decisionReason
    FROM portal_access_requests r WHERE r.approval_token_hash = p_token_hash;
  SELECT f.file_id AS fileId, f.original_name AS fileName, f.content_type AS contentType, f.size_bytes AS sizeBytes, f.scan_status AS scanStatus,
         f.storage_path AS storagePath   -- Node turns this into a short-lived signed download link and does not return it
    FROM files f JOIN portal_access_requests r ON f.entity_type = 'access_request' AND f.entity_id = r.reference
   WHERE r.approval_token_hash = p_token_hash;
END$$

-- POST /access-approval/:token — approve (billing name; user activated) or deny (reason ≥ 10 chars; draft company and user removed
-- so the same email/TIN can apply again). Single use.
CREATE PROCEDURE sp_access_approval_decide(IN p_token_hash CHAR(64), IN p_decision VARCHAR(10), IN p_billing_name VARCHAR(200), IN p_reason VARCHAR(1000), IN p_source VARCHAR(200),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_ref VARCHAR(20); DECLARE v_status VARCHAR(10); DECLARE v_exp DATETIME(3); DECLARE v_type VARCHAR(10); DECLARE v_subject VARCHAR(20);
  DECLARE v_email VARCHAR(700); DECLARE v_contact VARCHAR(700); DECLARE v_reviewer VARCHAR(100); DECLARE v_applicant VARCHAR(100); DECLARE v_decided DATETIME(3);
  DECLARE v_actor VARCHAR(100);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  START TRANSACTION;
  SELECT reference, status, approval_expires_at, account_type, subject_id, email, contact_name, reviewer_user_id, applicant_user_id, decided_at
    INTO v_ref, v_status, v_exp, v_type, v_subject, v_email, v_contact, v_reviewer, v_applicant, v_decided
    FROM portal_access_requests WHERE approval_token_hash = p_token_hash FOR UPDATE;
  IF v_ref IS NULL THEN ROLLBACK; SET o_err_code = 'APPROVAL_LINK_INVALID', o_err_msg = 'This approval link is not valid. It may be incomplete — open it from the email again.'; LEAVE proc; END IF;
  IF v_status <> 'Submitted' THEN ROLLBACK; SET o_err_code = 'ALREADY_DECIDED', o_err_msg = CONCAT(v_ref, ' was already ', IF(v_status = 'Approved', 'approved', 'denied'), ' on ', DATE_FORMAT(v_decided + INTERVAL 8 HOUR, '%d-%b-%Y %H:%i'), '. The link works once.'); LEAVE proc; END IF;
  IF v_exp < UTC_TIMESTAMP(3) THEN ROLLBACK; SET o_err_code = 'APPROVAL_LINK_EXPIRED', o_err_msg = CONCAT('This approval link expired on ', DATE_FORMAT(v_exp + INTERVAL 8 HOUR, '%d-%b-%Y %H:%i'), '. Open the request from the staff app instead.'); LEAVE proc; END IF;
  IF p_decision = 'approve' AND v_type = 'client' AND IFNULL(TRIM(p_billing_name), '') = '' THEN
    ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Enter the billing name printed on invoices.', o_err_fields = JSON_OBJECT('billingName', 'Required'); LEAVE proc;
  END IF;
  IF p_decision = 'deny' AND CHAR_LENGTH(TRIM(IFNULL(p_reason, ''))) < 10 THEN
    ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Tell the applicant why (at least 10 characters).', o_err_fields = JSON_OBJECT('reason', 'At least 10 characters'); LEAVE proc;
  END IF;
  SET v_actor = IFNULL(v_reviewer, IF(v_type = 'vendor', 'PROCUREMENT', 'AE'));

  IF p_decision = 'approve' THEN
    UPDATE users SET status = 'Active' WHERE user_id = v_applicant;
    IF v_type = 'client' THEN UPDATE clients SET billing_name = TRIM(p_billing_name) WHERE client_code = v_subject; END IF;
    UPDATE portal_access_requests SET status = 'Approved', billing_name = IF(v_type = 'client', TRIM(p_billing_name), NULL), decided_at = UTC_TIMESTAMP(3), decided_by = v_actor WHERE reference = v_ref;
    CALL sp_outbox_queue('access_request', v_ref, 'access.approved', 'Email', 'Applicant', 'Applicant', v_email, CONCAT('Portal access approved — ', v_ref), NULL,
         JSON_OBJECT('reference', v_ref, 'companyCode', IF(v_type = 'client', v_subject, NULL), 'billingName', p_billing_name), 0, v_contact);
    CALL sp_audit_write(v_actor, IF(v_type = 'vendor', 'APS_OFFICER', 'ACCOUNT_EXECUTIVE'),
         IF(v_type = 'vendor', 'vendor.portal_access_approved', 'client.portal_access_approved'), IF(v_type = 'vendor', 'vendor', 'client'), v_subject, NULL,
         JSON_OBJECT('status', 'Submitted'), JSON_OBJECT('reference', v_ref, 'billingName', p_billing_name, 'userActivated', TRUE), NULL, 'One-click approval link (email)');
  ELSE
    UPDATE portal_access_requests SET status = 'Rejected', decision_reason = TRIM(p_reason), decided_at = UTC_TIMESTAMP(3), decided_by = v_actor, applicant_user_id = NULL WHERE reference = v_ref;
    DELETE FROM user_roles WHERE user_id = v_applicant;
    DELETE FROM auth_otp_challenges WHERE user_id = v_applicant;
    DELETE FROM auth_password_resets WHERE user_id = v_applicant;
    DELETE FROM users WHERE user_id = v_applicant AND status = 'Inactive';
    IF v_type = 'vendor' THEN
      DELETE FROM vendors WHERE vendor_id = v_subject AND status = 'Pending';
    ELSE
      DELETE FROM client_branch_access WHERE client_code = v_subject AND EXISTS (SELECT 1 FROM clients WHERE client_code = v_subject AND status = 'Draft');
      DELETE FROM client_contacts WHERE client_code = v_subject AND EXISTS (SELECT 1 FROM clients WHERE client_code = v_subject AND status = 'Draft');
      UPDATE files SET owner_client_code = NULL WHERE owner_client_code = v_subject;
      DELETE FROM clients WHERE client_code = v_subject AND status = 'Draft';
    END IF;
    CALL sp_outbox_queue('access_request', v_ref, 'access.denied', 'Email', 'Applicant', 'Applicant', v_email, CONCAT('Portal access request not approved — ', v_ref), NULL,
         JSON_OBJECT('reference', v_ref, 'reason', TRIM(p_reason)), 0, v_contact);
    CALL sp_audit_write(v_actor, IF(v_type = 'vendor', 'APS_OFFICER', 'ACCOUNT_EXECUTIVE'),
         IF(v_type = 'vendor', 'vendor.portal_access_denied', 'client.portal_access_denied'), IF(v_type = 'vendor', 'vendor', 'client'), v_subject, NULL,
         JSON_OBJECT('status', 'Submitted'), JSON_OBJECT('reference', v_ref), TRIM(p_reason), 'One-click approval link (email)');
  END IF;
  COMMIT;
  SELECT reference, status, IF(status = 'Approved', 'Approved', 'Denied') AS statusLabel, decided_at AS decidedAt,
         IFNULL((SELECT full_name FROM users WHERE user_id = decided_by), decided_by) AS decidedBy, billing_name AS billingName,
         IF(account_type = 'client' AND status = 'Approved', subject_id, NULL) AS companyCode, decision_reason AS reason
    FROM portal_access_requests WHERE reference = v_ref;
END$$

DELIMITER ;
