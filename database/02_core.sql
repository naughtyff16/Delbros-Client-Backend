-- =====================================================================================================
-- 02_core.sql : shared functions and procedures used by every module
--   time helpers · settings · numbering · audit (hash chain) · caller context · notifications · outbox
--   workflow start · credit gate (BR-01) · e-wallet state · entitlement · BR-14 refund · BR-15 fee
--
-- ERROR CONTRACT (all write procedures)
--   Every write procedure ends with three OUT parameters:
--     o_err_code   VARCHAR(40)   NULL = success, otherwise e.g. VALIDATION_FAILED, NOT_FOUND, INVALID_STATE …
--     o_err_msg    VARCHAR(1000) message shown to the user
--     o_err_fields JSON          {"field": "message"} for form fields (NULL when not field-specific)
--   The Express controller maps o_err_code → HTTP status (see API sheet, "Error codes").
--   Unexpected SQL errors are RESIGNALled after ROLLBACK and become HTTP 500.
--
-- RDS NOTE: creating functions needs log_bin_trust_function_creators = 1 in the RDS parameter group.
-- =====================================================================================================
USE delbros_portal;

DROP FUNCTION IF EXISTS fn_now;
DROP FUNCTION IF EXISTS fn_manila_today;
DROP FUNCTION IF EXISTS fn_manila_date;
DROP FUNCTION IF EXISTS fn_tin9;
DROP FUNCTION IF EXISTS fn_setting_text;
DROP FUNCTION IF EXISTS fn_setting_num;
DROP FUNCTION IF EXISTS fn_user_role;
DROP FUNCTION IF EXISTS fn_days_overdue;
DROP FUNCTION IF EXISTS fn_aging_bucket;
DROP FUNCTION IF EXISTS fn_payment_status;
DROP FUNCTION IF EXISTS fn_client_gate;
DROP FUNCTION IF EXISTS fn_wallet_state;
DROP FUNCTION IF EXISTS fn_low_balance_warning;
DROP FUNCTION IF EXISTS fn_rescue_wallet_gate;
DROP FUNCTION IF EXISTS fn_rescue_is_open;
DROP FUNCTION IF EXISTS fn_available_units;
DROP FUNCTION IF EXISTS fn_contract_on_hire;
DROP FUNCTION IF EXISTS fn_contract_pending;
DROP FUNCTION IF EXISTS fn_contract_remaining;
DROP FUNCTION IF EXISTS fn_type_remaining;
DROP FUNCTION IF EXISTS fn_pretermination;
DROP FUNCTION IF EXISTS fn_bond_balance;
DROP FUNCTION IF EXISTS fn_dm_is_unsettled;
DROP FUNCTION IF EXISTS fn_min_billing_days;
DROP PROCEDURE IF EXISTS sp_next_number;
DROP PROCEDURE IF EXISTS sp_audit_write;
DROP PROCEDURE IF EXISTS sp_ctx_user;
DROP PROCEDURE IF EXISTS sp_notify_user;
DROP PROCEDURE IF EXISTS sp_notify_client_users;
DROP PROCEDURE IF EXISTS sp_notify_roles;
DROP PROCEDURE IF EXISTS sp_outbox_queue;
DROP PROCEDURE IF EXISTS sp_outbox_queue_roles;
DROP PROCEDURE IF EXISTS sp_workflow_start;
DROP PROCEDURE IF EXISTS sp_bond_refund_compute;

DELIMITER $$

-- ── Time ─────────────────────────────────────────────────────────────────────────────────────────────
CREATE FUNCTION fn_now() RETURNS DATETIME(3) NOT DETERMINISTIC NO SQL
  RETURN UTC_TIMESTAMP(3)$$

-- Philippines has no daylight saving: Manila = UTC + 8 h. Avoids depending on loaded time-zone tables.
CREATE FUNCTION fn_manila_today() RETURNS DATE NOT DETERMINISTIC NO SQL
  RETURN DATE(UTC_TIMESTAMP() + INTERVAL 8 HOUR)$$

CREATE FUNCTION fn_manila_date(p_utc DATETIME(3)) RETURNS DATE DETERMINISTIC NO SQL
  RETURN DATE(p_utc + INTERVAL 8 HOUR)$$

-- PDPA: TINs are encrypted; the "one TIN = one company" check uses tin_hash computed by the backend (fn_tin9 removed).

-- ── Settings ─────────────────────────────────────────────────────────────────────────────────────────
CREATE FUNCTION fn_setting_text(p_key VARCHAR(100), p_default VARCHAR(1000)) RETURNS VARCHAR(1000) READS SQL DATA
BEGIN
  DECLARE v VARCHAR(1000);
  SELECT setting_value INTO v FROM system_settings WHERE setting_key = p_key;
  RETURN IFNULL(v, p_default);
END$$

CREATE FUNCTION fn_setting_num(p_key VARCHAR(100), p_default DECIMAL(18,6)) RETURNS DECIMAL(18,6) READS SQL DATA
BEGIN
  DECLARE v VARCHAR(1000);
  SELECT setting_value INTO v FROM system_settings WHERE setting_key = p_key;
  RETURN IF(v IS NULL OR v NOT REGEXP '^-?[0-9]+(\\.[0-9]+)?$', p_default, CAST(v AS DECIMAL(18,6)));
END$$

CREATE FUNCTION fn_user_role(p_user_id VARCHAR(100)) RETURNS VARCHAR(30) READS SQL DATA
BEGIN
  DECLARE v VARCHAR(30);
  SELECT role_code INTO v FROM user_roles WHERE user_id = p_user_id ORDER BY role_code LIMIT 1;
  RETURN IFNULL(v, 'SYSTEM');
END$$

-- ── Numbering: one locked counter per series → never a duplicate number ─────────────────────────────
-- p_series 'EU' + prefix 'EU-' + pad 6 → EU-000782. The counter row stays locked until the caller commits.
CREATE PROCEDURE sp_next_number(IN p_series VARCHAR(60), IN p_prefix VARCHAR(30), IN p_pad INT, OUT o_no VARCHAR(60))
BEGIN
  INSERT INTO number_sequences (series_key, `last_value`) VALUES (p_series, LAST_INSERT_ID(1))
    ON DUPLICATE KEY UPDATE `last_value` = LAST_INSERT_ID(`last_value` + 1);
  -- never truncate: once the counter outgrows the pad, the number simply gets longer (V-999 → V-1000)
  SET o_no = CONCAT(p_prefix, IF(CHAR_LENGTH(LAST_INSERT_ID()) > p_pad, LAST_INSERT_ID(), LPAD(LAST_INSERT_ID(), p_pad, '0')));
END$$

-- ── Audit (NFR-008): append-only, each row = SHA-256(previous hash + content) ───────────────────────
CREATE PROCEDURE sp_audit_write(
  IN p_actor VARCHAR(100), IN p_actor_role VARCHAR(30), IN p_action VARCHAR(80),
  IN p_entity_type VARCHAR(40), IN p_entity_id VARCHAR(60), IN p_branch VARCHAR(10),
  IN p_before JSON, IN p_after JSON, IN p_reason VARCHAR(1000), IN p_source VARCHAR(200))
BEGIN
  DECLARE v_prev CHAR(64);
  DECLARE v_at DATETIME(3) DEFAULT UTC_TIMESTAMP(3);
  DECLARE v_hash CHAR(64);
  SELECT last_hash INTO v_prev FROM audit_chain_head WHERE id = 1 FOR UPDATE;
  SET v_hash = SHA2(CONCAT_WS('|', v_prev, DATE_FORMAT(v_at, '%Y-%m-%dT%H:%i:%s.%f'), p_actor, p_action, p_entity_type, p_entity_id,
                              IFNULL(CAST(p_before AS CHAR), 'null'), IFNULL(CAST(p_after AS CHAR), 'null'), IFNULL(p_reason, '')), 256);
  INSERT INTO audit_log (event_at, actor, actor_role, action, entity_type, entity_id, branch_code, before_json, after_json, reason, source, prev_hash, row_hash)
  VALUES (v_at, IFNULL(p_actor, 'system'), IFNULL(p_actor_role, 'SYSTEM'), p_action, p_entity_type, p_entity_id, p_branch, p_before, p_after, p_reason, IFNULL(p_source, 'System job'), v_prev, v_hash);
  UPDATE audit_chain_head SET last_hash = v_hash, last_audit_id = LAST_INSERT_ID() WHERE id = 1;
END$$

-- ── Caller context: every portal procedure starts here (scope = realm + client/vendor of the session user) ──
CREATE PROCEDURE sp_ctx_user(IN p_user_id VARCHAR(100), IN p_required_realm VARCHAR(20),
  OUT o_realm VARCHAR(20), OUT o_client_code VARCHAR(20), OUT o_vendor_id VARCHAR(20), OUT o_name VARCHAR(700), OUT o_email VARCHAR(700), OUT o_ok TINYINT)
BEGIN
  SET o_ok = 0, o_realm = NULL, o_client_code = NULL, o_vendor_id = NULL, o_name = NULL, o_email = NULL;
  SELECT realm, client_code, vendor_id, full_name, email INTO o_realm, o_client_code, o_vendor_id, o_name, o_email
    FROM users WHERE user_id = p_user_id AND status = 'Active';
  -- Refuse unless the realm is explicitly allowed: a vendor session never falls through to "all clients".
  IF o_realm IS NOT NULL AND (p_required_realm IS NULL OR o_realm = p_required_realm) THEN SET o_ok = 1; END IF;
END$$

-- ── In-app notifications ─────────────────────────────────────────────────────────────────────────────
CREATE PROCEDURE sp_notify_user(IN p_user_id VARCHAR(100), IN p_event VARCHAR(60), IN p_title VARCHAR(300), IN p_body TEXT, IN p_link VARCHAR(300))
BEGIN
  IF p_user_id IS NOT NULL AND EXISTS (SELECT 1 FROM users WHERE user_id = p_user_id) THEN
    INSERT INTO notifications (user_id, event_type, title, body, link, requires_ack)
    VALUES (p_user_id, p_event, p_title, LEFT(p_body, 2000), p_link,
            IFNULL((SELECT mode = 'Repeat until ack' FROM notification_rules WHERE event_type = p_event AND is_active = 1), 0));
  END IF;
END$$

CREATE PROCEDURE sp_notify_client_users(IN p_client_code VARCHAR(20), IN p_event VARCHAR(60), IN p_title VARCHAR(300), IN p_body TEXT, IN p_link VARCHAR(300))
BEGIN
  INSERT INTO notifications (user_id, event_type, title, body, link)
  SELECT user_id, p_event, p_title, LEFT(p_body, 2000), p_link FROM users
   WHERE realm = 'CLIENT_PORTAL' AND client_code = p_client_code AND status = 'Active';
END$$

-- Internal users holding any of p_roles (JSON array); p_branch NULL = all branches, else HO / that branch / granted access.
CREATE PROCEDURE sp_notify_roles(IN p_roles JSON, IN p_branch VARCHAR(10), IN p_event VARCHAR(60), IN p_title VARCHAR(300), IN p_body TEXT, IN p_link VARCHAR(300))
BEGIN
  INSERT INTO notifications (user_id, event_type, title, body, link)
  SELECT DISTINCT u.user_id, p_event, p_title, LEFT(p_body, 2000), p_link
    FROM users u JOIN user_roles r ON r.user_id = u.user_id
   WHERE u.realm = 'INTERNAL' AND u.status = 'Active' AND JSON_CONTAINS(p_roles, JSON_QUOTE(r.role_code))
     AND (p_branch IS NULL OR u.all_branches = 1 OR u.branch_code = p_branch
          OR EXISTS (SELECT 1 FROM user_branch_access a WHERE a.user_id = u.user_id AND a.branch_code = p_branch));
END$$

-- ── Email outbox (delivery log). Always 'Queued' — the worker sets Sent / Failed. ────────────────
-- PDPA: p_to and p_recipient_name are ciphertext copied from users / clients (never concatenated in SQL);
-- p_label is the role only ("Account Executive"). Subjects and bodies must not contain personal data.
CREATE PROCEDURE sp_outbox_queue(IN p_entity_type VARCHAR(40), IN p_entity_id VARCHAR(40), IN p_event VARCHAR(60), IN p_channel VARCHAR(5),
  IN p_audience VARCHAR(10), IN p_label VARCHAR(300), IN p_to VARCHAR(700), IN p_subject VARCHAR(300), IN p_body TEXT, IN p_data JSON, IN p_resend TINYINT,
  IN p_recipient_name VARCHAR(700))
BEGIN
  IF p_to IS NOT NULL AND p_to <> '' THEN
    INSERT INTO message_outbox (entity_type, entity_id, event_type, channel, audience, recipient_label, recipient_name, to_address, subject, body, template_data_json, is_resend)
    VALUES (p_entity_type, p_entity_id, p_event, p_channel, p_audience, p_label, p_recipient_name, p_to, p_subject, p_body, p_data, IFNULL(p_resend, 0));
  END IF;
END$$

-- One email per internal user holding a role (optionally limited to a branch). Label = p_label_suffix (role); name + address copied as ciphertext.
CREATE PROCEDURE sp_outbox_queue_roles(IN p_entity_type VARCHAR(40), IN p_entity_id VARCHAR(40), IN p_event VARCHAR(60), IN p_roles JSON, IN p_branch VARCHAR(10),
  IN p_label_suffix VARCHAR(200), IN p_subject VARCHAR(300), IN p_body TEXT, IN p_data JSON)
BEGIN
  INSERT INTO message_outbox (entity_type, entity_id, event_type, channel, audience, recipient_label, recipient_user_id, recipient_name, to_address, subject, body, template_data_json)
  SELECT DISTINCT p_entity_type, p_entity_id, p_event, 'Email', 'Delbros', p_label_suffix, u.user_id, u.full_name, u.email, p_subject, p_body, p_data
    FROM users u JOIN user_roles r ON r.user_id = u.user_id
   WHERE u.realm = 'INTERNAL' AND u.status = 'Active' AND JSON_CONTAINS(p_roles, JSON_QUOTE(r.role_code))
     AND (p_branch IS NULL OR u.branch_code = p_branch);
END$$

-- ── Workflow start: steps JSON = [{"label":"Credit & Collection","roles":["CNC_OFFICER"]}, …] ─────────
CREATE PROCEDURE sp_workflow_start(IN p_matrix VARCHAR(40), IN p_title VARCHAR(300), IN p_subject_type VARCHAR(40), IN p_subject_id VARCHAR(40),
  IN p_amount DECIMAL(15,2), IN p_branch VARCHAR(10), IN p_requested_by VARCHAR(100), IN p_steps JSON, OUT o_workflow_id VARCHAR(20))
BEGIN
  DECLARE v_esc DECIMAL(18,6);
  DECLARE v_roles JSON;
  DECLARE v_label VARCHAR(100);
  SET v_esc = fn_setting_num(CONCAT('wf.escalation_hours.', p_matrix), fn_setting_num('wf.escalation_hours', 48));
  CALL sp_next_number('WF', 'WF-', 5, o_workflow_id);
  INSERT INTO workflows (workflow_id, matrix_code, title, subject_type, subject_id, amount, branch_code, requested_by, status, current_step)
  VALUES (o_workflow_id, p_matrix, p_title, p_subject_type, p_subject_id, p_amount, p_branch, p_requested_by, 'Pending', 1);
  INSERT INTO workflow_steps (workflow_id, step_no, label, roles_json, decision, due_at)
  SELECT o_workflow_id, s.n, s.label, s.roles, 'Pending', IF(s.n = 1, UTC_TIMESTAMP(3) + INTERVAL v_esc HOUR, NULL)
    FROM JSON_TABLE(p_steps, '$[*]' COLUMNS (n FOR ORDINALITY, label VARCHAR(100) PATH '$.label', roles JSON PATH '$.roles')) s;
  SELECT label, roles_json INTO v_label, v_roles FROM workflow_steps WHERE workflow_id = o_workflow_id AND step_no = 1;
  CALL sp_notify_roles(v_roles, NULL, 'workflow.task', CONCAT('Approval needed: ', p_title),
       CONCAT(v_label, IF(p_amount IS NULL, '', CONCAT(' · ₱', FORMAT(p_amount, 2)))), '/approvals');
  CALL sp_audit_write(p_requested_by, fn_user_role(p_requested_by), 'workflow.started', p_subject_type, p_subject_id, p_branch,
       NULL, JSON_OBJECT('workflow', o_workflow_id, 'matrixCode', p_matrix), NULL, NULL);
END$$

-- ── Invoices: days overdue, aging bucket, payment status ─────────────────────────────────────────────
-- An invoice awaiting acknowledgment has no due date → never overdue.
CREATE FUNCTION fn_days_overdue(p_due DATE) RETURNS INT NOT DETERMINISTIC NO SQL
  RETURN IF(p_due IS NULL, 0, GREATEST(0, DATEDIFF(fn_manila_today(), p_due)))$$

-- Six buckets: current, d1_30, d31_60, d61_90, d91_180, d180
CREATE FUNCTION fn_aging_bucket(p_days INT) RETURNS VARCHAR(10) DETERMINISTIC NO SQL
  RETURN CASE WHEN p_days <= 0 THEN 'current' WHEN p_days <= 30 THEN 'd1_30' WHEN p_days <= 60 THEN 'd31_60'
              WHEN p_days <= 90 THEN 'd61_90' WHEN p_days <= 180 THEN 'd91_180' ELSE 'd180' END$$

CREATE FUNCTION fn_payment_status(p_status VARCHAR(20), p_balance DECIMAL(15,2), p_paid DECIMAL(15,2), p_credited DECIMAL(15,2), p_due DATE)
RETURNS VARCHAR(20) NOT DETERMINISTIC NO SQL
  RETURN CASE
    WHEN p_status = 'Cancelled' THEN 'Cancelled'
    WHEN p_balance <= 0.005 THEN IF(p_credited > 0 AND p_paid <= 0.005, 'Credited', 'Paid')
    WHEN p_due IS NOT NULL AND p_due < fn_manila_today() THEN 'Overdue'
    WHEN p_paid > 0 OR p_credited > 0 THEN 'Partially Paid'
    ELSE 'Unpaid' END$$

-- ── BR-01 credit gate. Returns JSON {allowed, code, reason, overrideUntil} ─────────────────────────
-- p_action: PORTAL_EWA | EWA_CREATE | RESCUE_REQUEST | GATE_IN …  GATE_IN is never blocked.
CREATE FUNCTION fn_client_gate(p_client_code VARCHAR(20), p_action VARCHAR(30)) RETURNS JSON READS SQL DATA
BEGIN
  DECLARE v_status VARCHAR(20); DECLARE v_name VARCHAR(200); DECLARE v_online TINYINT; DECLARE v_rescue TINYINT;
  DECLARE v_ov DATETIME(3);
  SELECT status, client_name, allow_online, allow_rescue INTO v_status, v_name, v_online, v_rescue FROM clients WHERE client_code = p_client_code;
  IF v_status IS NULL THEN RETURN JSON_OBJECT('allowed', FALSE, 'code', 'CLIENT_NOT_FOUND', 'reason', 'Client record not found.'); END IF;
  IF p_action = 'GATE_IN' THEN RETURN JSON_OBJECT('allowed', TRUE); END IF;
  IF v_status IN ('Hold','Blacklist','Inactive','Draft') THEN
    SELECT MAX(valid_until) INTO v_ov FROM gate_overrides
     WHERE client_code = p_client_code AND gate_action = p_action AND status = 'Approved' AND valid_until >= UTC_TIMESTAMP(3);
    IF v_ov IS NOT NULL THEN
      RETURN JSON_OBJECT('allowed', TRUE, 'code', 'OVERRIDE', 'overrideUntil', v_ov,
                         'reason', CONCAT('Authorised override until ', DATE_FORMAT(v_ov, '%Y-%m-%d'), ' (DBL-CNC-001).'));
    END IF;
    RETURN JSON_OBJECT('allowed', FALSE, 'code', 'CREDIT_GATE_BLOCKED', 'status', v_status,
      'reason', CONCAT(v_name, ' ', CASE v_status WHEN 'Hold' THEN 'is ON HOLD for overdue balance' WHEN 'Draft' THEN 'is not yet accredited (Draft)'
                                       WHEN 'Blacklist' THEN 'is BLACKLISTED' ELSE 'is INACTIVE' END,
                       '. Chassis release, gate pass, repair scheduling and new services are blocked (BR-01).'));
  END IF;
  IF p_action = 'PORTAL_EWA' AND v_online = 0 THEN
    RETURN JSON_OBJECT('allowed', FALSE, 'code', 'ELIGIBILITY', 'reason', 'Online EWA is not enabled for this client (Allow Online = off).');
  END IF;
  IF p_action IN ('RESCUE_DISPATCH','RESCUE_REQUEST') AND v_rescue = 0 THEN
    RETURN JSON_OBJECT('allowed', FALSE, 'code', 'ELIGIBILITY', 'reason', 'Rescue service is not enabled for this client (Allow Rescue = off).');
  END IF;
  RETURN JSON_OBJECT('allowed', TRUE);
END$$

-- ── E-wallet state (proposed, EWL-004): healthy ≥ 125 % of minimum; near; below; negative ────────────
CREATE FUNCTION fn_wallet_state(p_balance DECIMAL(15,2), p_minimum DECIMAL(15,2)) RETURNS VARCHAR(10) READS SQL DATA
  RETURN CASE WHEN p_balance < 0 THEN 'negative' WHEN p_balance < p_minimum THEN 'below'
              WHEN p_balance < p_minimum * fn_setting_num('ewl.near_factor', 1.25) THEN 'near' ELSE 'healthy' END$$

CREATE FUNCTION fn_low_balance_warning(p_balance DECIMAL(15,2), p_minimum DECIMAL(15,2), p_context VARCHAR(10)) RETURNS VARCHAR(300) DETERMINISTIC NO SQL
  RETURN CASE
    WHEN p_balance < 0 AND p_context = 'EWA' THEN 'Your e-wallet is negative. New EWAs are not blocked by the balance, but the shortfall is owed — please top up.'
    WHEN p_balance < 0 THEN 'Your e-wallet is negative. The rescue is still accepted; its charge is deducted afterwards and adds to what you owe — please top up.'
    WHEN p_balance < p_minimum AND p_context = 'EWA' THEN 'Your e-wallet is below the contract minimum. New EWAs are not blocked by the balance; please top up so rescue and repair charges are covered.'
    WHEN p_balance < p_minimum THEN 'Your e-wallet is below the contract minimum. The rescue is still accepted; please top up so the charge is covered.'
    ELSE NULL END$$

-- res.funded_wallet_rule: none (provisional — warn only) | wallet_exists | positive | minimum
CREATE FUNCTION fn_rescue_wallet_gate(p_client_code VARCHAR(20)) RETURNS JSON READS SQL DATA
BEGIN
  DECLARE v_rule VARCHAR(20) DEFAULT fn_setting_text('res.funded_wallet_rule', 'none');
  DECLARE v_bal DECIMAL(15,2); DECLARE v_min DECIMAL(15,2); DECLARE v_has INT DEFAULT 0;
  SELECT COUNT(*), MAX(balance), MAX(minimum_balance) INTO v_has, v_bal, v_min FROM ewallets WHERE client_code = p_client_code;
  IF v_rule NOT IN ('wallet_exists','positive','minimum') THEN
    IF v_has = 0 THEN RETURN JSON_OBJECT('allowed', TRUE, 'warning', 'You have no e-wallet yet. The rescue is still accepted; its charge is billed to you and the e-wallet opens once Treasury confirms your first deposit.'); END IF;
    RETURN JSON_OBJECT('allowed', TRUE, 'warning', fn_low_balance_warning(v_bal, v_min, 'RESCUE'));
  END IF;
  IF v_has = 0 THEN RETURN JSON_OBJECT('allowed', FALSE, 'code', 'WALLET', 'reason', 'Rescue needs a funded e-wallet, and your e-wallet is not open yet. It opens once Treasury confirms your first deposit — request a top-up or contact your Account Executive.'); END IF;
  IF v_rule = 'positive' AND v_bal <= 0 THEN RETURN JSON_OBJECT('allowed', FALSE, 'code', 'WALLET', 'reason', 'Rescue needs a funded e-wallet: your balance is ₱0 or below. Top up first, or call your Account Executive in an emergency.'); END IF;
  IF v_rule = 'minimum' AND v_bal < v_min THEN RETURN JSON_OBJECT('allowed', FALSE, 'code', 'WALLET', 'reason', 'Rescue needs your e-wallet at or above the contract minimum. Top up first, or call your Account Executive in an emergency.'); END IF;
  RETURN JSON_OBJECT('allowed', TRUE, 'warning', fn_low_balance_warning(v_bal, v_min, 'RESCUE'));
END$$

CREATE FUNCTION fn_rescue_is_open(p_status VARCHAR(20)) RETURNS TINYINT DETERMINISTIC NO SQL
  RETURN p_status IN ('Requested','Verified','Confirmed','Dispatched','In Progress')$$

-- ── Fleet availability & contract entitlement ────────────────────────────────────────────────────────
CREATE FUNCTION fn_available_units(p_branch VARCHAR(10), p_type VARCHAR(30)) RETURNS INT READS SQL DATA
  RETURN (SELECT COUNT(*) FROM chassis WHERE branch_code = p_branch AND chassis_type = p_type AND status = 'Available')$$

-- Units on hire under a contract (On Hire or Rescue); p_type NULL = all types.
CREATE FUNCTION fn_contract_on_hire(p_contract VARCHAR(30), p_type VARCHAR(30)) RETURNS INT READS SQL DATA
  RETURN (SELECT COUNT(*) FROM chassis WHERE current_contract_no = p_contract AND status IN ('On Hire','Rescue')
           AND (p_type IS NULL OR chassis_type = p_type))$$

-- Units still to be released on open EWAs (Active, Partially Used, Extension Pending).
CREATE FUNCTION fn_contract_pending(p_contract VARCHAR(30), p_type VARCHAR(30)) RETURNS INT READS SQL DATA
  RETURN (SELECT IFNULL(SUM(GREATEST(0, l.qty - (SELECT COUNT(*) FROM ewa_line_chassis c WHERE c.eu_no = l.eu_no AND c.equipment_type = l.equipment_type))), 0)
            FROM ewas e JOIN ewa_lines l ON l.eu_no = e.eu_no
           WHERE e.contract_no = p_contract AND e.status IN ('Active','Partially Used','Extension Pending')
             AND (p_type IS NULL OR l.equipment_type = p_type))$$

CREATE FUNCTION fn_contract_remaining(p_contract VARCHAR(30)) RETURNS INT READS SQL DATA
  RETURN GREATEST(0, (SELECT unit_qty FROM contracts WHERE contract_no = p_contract)
                     - fn_contract_on_hire(p_contract, NULL) - fn_contract_pending(p_contract, NULL))$$

-- What can still be requested of a type: min(type entitlement left, contract total left). NULL = type not on contract.
CREATE FUNCTION fn_type_remaining(p_contract VARCHAR(30), p_type VARCHAR(30)) RETURNS INT READS SQL DATA
BEGIN
  DECLARE v_on INT; DECLARE v_by_type TINYINT; DECLARE v_qty INT; DECLARE v_total INT;
  SELECT COUNT(*) INTO v_on FROM contract_rates WHERE contract_no = p_contract AND equipment_type = p_type;
  IF v_on = 0 THEN RETURN NULL; END IF;
  SELECT c.entitlement_by_type, r.entitled_qty INTO v_by_type, v_qty
    FROM contracts c JOIN contract_rates r ON r.contract_no = c.contract_no WHERE c.contract_no = p_contract AND r.equipment_type = p_type;
  SET v_total = fn_contract_remaining(p_contract);
  IF v_by_type = 0 AND IFNULL(v_qty, 0) = 0 THEN RETURN v_total; END IF;
  RETURN LEAST(v_total, GREATEST(0, IFNULL(v_qty, 0) - fn_contract_on_hire(p_contract, p_type) - fn_contract_pending(p_contract, p_type)));
END$$

CREATE FUNCTION fn_min_billing_days(p_contract VARCHAR(30)) RETURNS INT READS SQL DATA
  RETURN (SELECT IFNULL(min_billing_days, IF(contract_type = 'QLP', 10, 1)) FROM contracts WHERE contract_no = p_contract)$$

-- ── BR-15 pre-termination fee (proposed): daily rates of units on hire × lock-in days left, capped ────
-- Returns {lockInEnd, inLockIn, remainingDays, chargeableDays, fee}
CREATE FUNCTION fn_pretermination(p_effective DATE, p_lock_in_months INT, p_as_of DATE, p_daily_total DECIMAL(15,2), p_cap_days INT)
RETURNS JSON DETERMINISTIC NO SQL
BEGIN
  DECLARE v_end DATE DEFAULT IF(p_lock_in_months > 0, DATE_ADD(p_effective, INTERVAL p_lock_in_months MONTH), NULL);
  DECLARE v_left INT DEFAULT IF(v_end IS NULL, 0, GREATEST(0, DATEDIFF(v_end, p_as_of)));
  DECLARE v_days INT DEFAULT LEAST(v_left, p_cap_days);
  RETURN JSON_OBJECT('lockInEnd', v_end, 'inLockIn', v_left > 0, 'remainingDays', v_left, 'chargeableDays', v_days,
                     'fee', ROUND(p_daily_total * v_days, 2));
END$$

-- ── Cash bond (BR-14) ────────────────────────────────────────────────────────────────────────────────
-- Bond still held = amount − refunded withdrawals − outcome amount (when closed by an outcome without a refund).
CREATE FUNCTION fn_bond_balance(p_bond_id VARCHAR(20)) RETURNS DECIMAL(15,2) READS SQL DATA
BEGIN
  DECLARE v_amt DECIMAL(15,2); DECLARE v_out DECIMAL(15,2); DECLARE v_ref DECIMAL(15,2);
  SELECT amount, outcome_amount INTO v_amt, v_out FROM cash_bonds WHERE bond_id = p_bond_id;
  SELECT IFNULL(SUM(amount), 0) INTO v_ref FROM cash_bond_withdrawals WHERE bond_id = p_bond_id AND status = 'Refunded';
  RETURN ROUND(v_amt - v_ref - IF(v_out IS NOT NULL AND v_ref = 0, v_out, 0), 2);
END$$

-- A debit memo posted/approved, not on an invoice and not settled from the e-wallet → counts once in the refund.
CREATE FUNCTION fn_dm_is_unsettled(p_memo_no VARCHAR(20)) RETURNS TINYINT READS SQL DATA
BEGIN
  DECLARE v_client VARCHAR(20); DECLARE v_src VARCHAR(40); DECLARE v_ok TINYINT DEFAULT 0;
  SELECT client_code, COALESCE(rescue_no, jo_no, reference_id),
         (memo_type = 'Debit' AND status IN ('Posted','Approved') AND applied_to IS NULL AND reference_invoice_no IS NULL)
    INTO v_client, v_src, v_ok FROM memos WHERE memo_no = p_memo_no;
  IF v_ok = 0 OR v_ok IS NULL THEN RETURN 0; END IF;
  RETURN NOT EXISTS (SELECT 1 FROM ewallet_txns t WHERE t.client_code = v_client AND t.txn_type = 'Deduction' AND t.reversed_by_txn_id IS NULL
                       AND (t.reference_id = p_memo_no OR (v_src IS NOT NULL AND t.reference_id = v_src)));
END$$

-- Full BR-14 calculation for one bond; also used by the withdrawal request and the refund re-check.
CREATE PROCEDURE sp_bond_refund_compute(IN p_bond_id VARCHAR(20),
  OUT o_bond DECIMAL(15,2), OUT o_unpaid DECIMAL(15,2), OUT o_negative_wallet DECIMAL(15,2), OUT o_pending_dm DECIMAL(15,2),
  OUT o_posted_unsettled_dm DECIMAL(15,2), OUT o_deductions DECIMAL(15,2), OUT o_refundable DECIMAL(15,2), OUT o_shortfall DECIMAL(15,2),
  OUT o_sources JSON, OUT o_contract_no VARCHAR(30), OUT o_contract_status VARCHAR(20), OUT o_contract_expiry DATE, OUT o_contract_ended TINYINT)
BEGIN
  DECLARE v_client VARCHAR(20);
  SELECT client_code, contract_no INTO v_client, o_contract_no FROM cash_bonds WHERE bond_id = p_bond_id;
  SET o_bond = fn_bond_balance(p_bond_id);
  SELECT IFNULL(ROUND(SUM(balance), 2), 0) INTO o_unpaid FROM invoices WHERE client_code = v_client AND status <> 'Draft' AND balance > 0;
  SELECT IFNULL(IF(MAX(balance) < 0, -MAX(balance), 0), 0) INTO o_negative_wallet FROM ewallets WHERE client_code = v_client;
  SELECT IFNULL(ROUND(SUM(amount), 2), 0) INTO o_pending_dm FROM memos WHERE client_code = v_client AND memo_type = 'Debit' AND status = 'Pending Approval';
  SELECT IFNULL(ROUND(SUM(amount), 2), 0) INTO o_posted_unsettled_dm FROM memos WHERE client_code = v_client AND fn_dm_is_unsettled(memo_no) = 1;
  SET o_deductions = ROUND(o_unpaid + o_negative_wallet + o_pending_dm + o_posted_unsettled_dm, 2);
  SET o_refundable = GREATEST(0, ROUND(o_bond - o_deductions, 2));
  SET o_shortfall = GREATEST(0, ROUND(o_deductions - o_bond, 2));
  SET o_sources = JSON_OBJECT(
    'invoices', (SELECT IFNULL(JSON_ARRAYAGG(JSON_OBJECT('invoiceNo', invoice_no, 'balance', balance)), JSON_ARRAY()) FROM invoices WHERE client_code = v_client AND status <> 'Draft' AND balance > 0),
    'pendingMemos', (SELECT IFNULL(JSON_ARRAYAGG(JSON_OBJECT('memoNo', memo_no, 'amount', amount)), JSON_ARRAY()) FROM memos WHERE client_code = v_client AND memo_type = 'Debit' AND status = 'Pending Approval'),
    'unsettledMemos', (SELECT IFNULL(JSON_ARRAYAGG(JSON_OBJECT('memoNo', memo_no, 'amount', amount)), JSON_ARRAY()) FROM memos WHERE client_code = v_client AND fn_dm_is_unsettled(memo_no) = 1));
  SELECT MAX(status), MAX(expiry_date) INTO o_contract_status, o_contract_expiry FROM contracts WHERE contract_no = o_contract_no;  -- aggregate: always one row (no NOT FOUND in callers' cursor loops)
  SET o_contract_ended = (o_contract_no IS NULL OR o_contract_status IS NULL OR o_contract_status IN ('Expired','Terminated','Renewed'));
END$$

DELIMITER ;
