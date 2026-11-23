-- =====================================================================================================
-- 05_sp_ewa.sql : Equipment Withdrawal Authorization (EWA) — New EWA options, create, list, details,
--                 cancel (client, before any release), extension request (BR-06), resend EWA email (GAT-002)
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_ewa_queue_delivery;
DROP PROCEDURE IF EXISTS sp_ewa_options;
DROP PROCEDURE IF EXISTS sp_ewa_list;
DROP PROCEDURE IF EXISTS sp_ewa_get;
DROP PROCEDURE IF EXISTS sp_ewa_create;
DROP PROCEDURE IF EXISTS sp_ewa_cancel;
DROP PROCEDURE IF EXISTS sp_ewa_request_extension;
DROP PROCEDURE IF EXISTS sp_ewa_resend_email;

DELIMITER $$

-- Full-detail EWA email (notification N08): the portal user who created it, the company email, the pickup branch's
-- Branch Generalists and the Account Executive — one row per address, status Queued.
CREATE PROCEDURE sp_ewa_queue_delivery(IN p_eu_no VARCHAR(20), IN p_resend TINYINT)
BEGIN
  DECLARE v_client VARCHAR(20); DECLARE v_branch VARCHAR(10); DECLARE v_creator VARCHAR(100); DECLARE v_subject VARCHAR(300); DECLARE v_data JSON;
  SELECT client_code, branch_code, created_by INTO v_client, v_branch, v_creator FROM ewas WHERE eu_no = p_eu_no;
  SET v_subject = CONCAT(IF(p_resend = 1, 'Resent: ', ''), 'EWA ', p_eu_no, ' — ', (SELECT client_name FROM clients WHERE client_code = v_client));
  SET v_data = JSON_OBJECT('euNo', p_eu_no, 'template', 'ewa_full_detail');
  -- PDPA: names and addresses are copied as ciphertext (labels are roles only). Ciphertext cannot be compared,
  -- so duplicate addresses are not removed here — the worker skips a second send to the same decrypted address.
  INSERT INTO message_outbox (entity_type, entity_id, event_type, channel, audience, recipient_label, recipient_user_id, recipient_name, to_address, subject, template_data_json, is_resend)
  SELECT 'ewa', p_eu_no, 'ewa.created', 'Email', x.audience, x.label, x.uid, x.rname, x.addr, v_subject, v_data, IFNULL(p_resend, 0)
    FROM (
      SELECT 1 AS ord, 'Client' AS audience, 'Created the EWA' AS label, u.user_id AS uid, u.full_name AS rname, u.email AS addr FROM users u WHERE u.user_id = v_creator AND u.realm = 'CLIENT_PORTAL'
      UNION ALL SELECT 2, 'Client', 'Company email', NULL, NULL, c.email FROM clients c WHERE c.client_code = v_client AND c.email IS NOT NULL
      UNION ALL SELECT 3, 'Delbros', CONCAT('Branch Generalist, ', v_branch), u.user_id, u.full_name, u.email FROM users u JOIN user_roles r ON r.user_id = u.user_id
                 WHERE u.realm = 'INTERNAL' AND u.status = 'Active' AND r.role_code = 'BRANCH_GENERALIST' AND u.branch_code = v_branch
      UNION ALL SELECT 4, 'Delbros', 'Account Executive', u.user_id, u.full_name, u.email FROM clients c JOIN users u ON u.user_id = c.ae_user_id WHERE c.client_code = v_client
    ) x
   WHERE x.addr IS NOT NULL AND x.addr <> ''
   ORDER BY x.ord;
END$$

-- GET /portal/ewa/options — everything the New EWA dialog needs.
-- RS1 header {blocked, clientName, validityHours, walletNotice, accountExecutive, creditContact}
-- RS2 active contracts with entitlement per type · RS3 eligible pickup branches · RS4 availability (branch × type)
-- RS5 drivers used before · RS6 trucks used before
CREATE PROCEDURE sp_ewa_options(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_gate JSON; DECLARE v_status VARCHAR(20); DECLARE v_blocked JSON DEFAULT NULL; DECLARE v_branches INT; DECLARE v_contracts INT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  SET v_gate = fn_client_gate(v_client, 'PORTAL_EWA');
  SELECT status INTO v_status FROM clients WHERE client_code = v_client;
  SELECT COUNT(*) INTO v_branches FROM client_branch_access a JOIN branches b ON b.branch_code = a.branch_code
   WHERE a.client_code = v_client AND b.is_head_office = 0 AND b.is_active = 1;
  SELECT COUNT(*) INTO v_contracts FROM contracts WHERE client_code = v_client AND status = 'Active';
  IF JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.allowed')) <> 'true' THEN
    SET v_blocked = CASE
      WHEN v_status = 'Hold' THEN JSON_OBJECT('code', 'HOLD', 'title', 'Your account is on hold', 'reason', 'New EWAs and chassis release are blocked until the overdue balance is settled and the hold is lifted (BR-01).')
      WHEN v_status = 'Draft' THEN JSON_OBJECT('code', 'NOT_ACCREDITED', 'title', 'Your company is not yet accredited', 'reason', 'EWAs can be created once Delbros completes your accreditation.')
      WHEN JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.code')) = 'ELIGIBILITY' THEN JSON_OBJECT('code', 'ONLINE_OFF', 'title', 'Online EWA is not enabled for your account', 'reason', 'Allow Online is off for your account, so EWAs cannot be created in the portal. Your Account Executive can book the pickup or enable online EWAs.')
      ELSE JSON_OBJECT('code', 'ACCOUNT', 'title', 'EWA creation unavailable', 'reason', JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.reason'))) END;
  ELSEIF v_branches = 0 THEN
    SET v_blocked = JSON_OBJECT('code', 'NO_BRANCH', 'title', 'No pickup branch is enabled for your account', 'reason', 'Your account has no branch set up for chassis pickup (CWS branch access). Ask your Account Executive to add one.');
  ELSEIF v_contracts = 0 THEN
    SET v_blocked = JSON_OBJECT('code', 'NO_CONTRACT', 'title', 'No active contract', 'reason', 'An EWA is issued against an active lease contract. Your Account Executive can help with a new or renewed contract.');
  END IF;

  -- RS1
  SELECT v_blocked AS blocked, c.client_name AS clientName, CAST(fn_setting_num('gat.ewa_validity_hours', 24) AS UNSIGNED) AS validityHours,
         (SELECT fn_low_balance_warning(w.balance, w.minimum_balance, 'EWA') FROM ewallets w WHERE w.client_code = c.client_code) AS walletNotice,
         JSON_OBJECT('role', 'Your Account Executive', 'name', ae.full_name, 'phone', ae.mobile, 'email', ae.email) AS accountExecutive,
         (SELECT JSON_OBJECT('role', 'Credit & Collection', 'name', u.full_name, 'phone', u.mobile, 'email', u.email) FROM users u JOIN user_roles r ON r.user_id = u.user_id
           WHERE r.role_code = 'CNC_OFFICER' AND u.status = 'Active' ORDER BY (u.branch_code = c.branch_code) DESC, u.user_id LIMIT 1) AS creditContact
    FROM clients c LEFT JOIN users ae ON ae.user_id = c.ae_user_id WHERE c.client_code = v_client;
  -- RS2 contracts + entitlement per type
  SELECT k.contract_no AS contractNo, k.contract_type AS contractType, k.contract_class AS class, k.expiry_date AS expiryDate,
         k.unit_qty AS unitQty, fn_contract_on_hire(k.contract_no, NULL) AS onHire, fn_contract_pending(k.contract_no, NULL) AS pending,
         fn_contract_remaining(k.contract_no) AS contractRemaining,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('equipmentType', r.equipment_type, 'dailyRate', r.daily_rate,
                    'entitled', IF(k.entitlement_by_type = 1 OR IFNULL(r.entitled_qty, 0) > 0, IFNULL(r.entitled_qty, 0), NULL),
                    'onHire', fn_contract_on_hire(k.contract_no, r.equipment_type), 'pending', fn_contract_pending(k.contract_no, r.equipment_type),
                    'remaining', fn_type_remaining(k.contract_no, r.equipment_type)))
            FROM contract_rates r WHERE r.contract_no = k.contract_no) AS types
    FROM contracts k WHERE k.client_code = v_client AND k.status = 'Active' ORDER BY k.contract_no;
  -- RS3 eligible pickup branches
  SELECT b.branch_code AS code, b.branch_name AS name FROM client_branch_access a JOIN branches b ON b.branch_code = a.branch_code
   WHERE a.client_code = v_client AND b.is_head_office = 0 AND b.is_active = 1 ORDER BY b.branch_name;
  -- RS4 free units per branch and type
  SELECT a.branch_code AS branchCode, t.equipment_type AS equipmentType,
         (SELECT COUNT(*) FROM chassis ch WHERE ch.branch_code = a.branch_code AND ch.chassis_type = t.equipment_type AND ch.status = 'Available') AS available
    FROM client_branch_access a JOIN branches b ON b.branch_code = a.branch_code CROSS JOIN equipment_types t
   WHERE a.client_code = v_client AND b.is_head_office = 0 AND b.is_active = 1 AND t.is_active = 1;
  -- RS5 drivers used before (latest 20 distinct licences)
  SELECT driver_name AS name, driver_license_no AS licence, last_used AS lastUsed FROM (
    SELECT driver_name, driver_license_no, created_at AS last_used, ROW_NUMBER() OVER (PARTITION BY driver_license_hash ORDER BY created_at DESC) AS rn  -- PDPA: grouped by blind index
      FROM ewas WHERE client_code = v_client) d WHERE rn = 1 ORDER BY last_used DESC LIMIT 20;
  -- RS6 trucks used before (latest 20 distinct plates; OR/CR from the EWA or a gate pass)
  SELECT plate, trucker, truck_orcr AS truckOrcr, last_used AS lastUsed FROM (
    SELECT e.truck_plate_no AS plate, e.trucker, COALESCE(e.truck_orcr, (SELECT g.truck_orcr FROM gate_passes g WHERE g.eu_no = e.eu_no AND g.truck_orcr IS NOT NULL LIMIT 1)) AS truck_orcr,
           e.created_at AS last_used, ROW_NUMBER() OVER (PARTITION BY e.truck_plate_no ORDER BY e.created_at DESC) AS rn
      FROM ewas e WHERE e.client_code = v_client) t WHERE rn = 1 ORDER BY last_used DESC LIMIT 20;
END$$

-- GET /portal/ewa — list with search, filters and paging. RS1 rows · RS2 {total}
-- Each row carries everything the portal EWA list shows without a second call: lines with the released chassis,
-- gate releases (with the truck OR/CR captured at the gate), extension history and the pending approval step,
-- and the full-detail email log. Status is the effective one (validity passed → Expired even before the expiry job runs).
-- PDPA: driver names are encrypted, so free-text search covers EU no., plate, trucker and contract; p_q_licence_hash (HMAC of the
-- search text as a licence number, computed by Node) also finds an exact driver licence. Names / addresses inside the JSON
-- columns are ciphertext and are decrypted by the backend for the response.
CREATE PROCEDURE sp_ewa_list(IN p_user_id VARCHAR(100), IN p_q VARCHAR(100), IN p_q_licence_hash CHAR(64), IN p_status VARCHAR(20), IN p_from DATE, IN p_to DATE,
  IN p_page INT, IN p_page_size INT, OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_size INT DEFAULT LEAST(GREATEST(IFNULL(p_page_size, 8), 1), 100);
  DECLARE v_offset INT DEFAULT (GREATEST(IFNULL(p_page, 1), 1) - 1) * LEAST(GREATEST(IFNULL(p_page_size, 8), 1), 100);
  DECLARE v_q VARCHAR(102) DEFAULT CONCAT('%', IFNULL(TRIM(p_q), ''), '%');
  DECLARE v_now DATETIME(3) DEFAULT UTC_TIMESTAMP(3);
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  SELECT e.eu_no AS euNo, e.client_code AS clientCode, c.client_name AS clientName, e.branch_code AS branchCode, e.contract_no AS contractNo,
         e.driver_name AS driverName, e.driver_license_no AS driverLicenseNo, e.truck_plate_no AS truckPlateNo, e.trucker, e.truck_orcr AS truckOrcr,
         e.expected_pickup_at AS expectedPickupAt, e.remarks,
         IF(e.status IN ('Active','Partially Used') AND e.valid_until < v_now, 'Expired', e.status) AS status,
         e.created_at AS createdAt, e.created_via AS createdVia, e.created_by AS createdBy, cu.full_name AS createdByName,
         e.valid_until AS validUntil, e.extension_count AS extensionCount,
         e.cancelled_at AS cancelledAt, e.cancelled_by AS cancelledBy, cb.full_name AS cancelledByName, e.cancel_reason AS cancelReason, e.expired_lapsed_units AS lapsedUnits,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('equipmentType', l.equipment_type, 'qty', l.qty,
                   'usedChassis', IFNULL((SELECT JSON_ARRAYAGG(x.chassis_no) FROM ewa_line_chassis x WHERE x.eu_no = l.eu_no AND x.equipment_type = l.equipment_type), JSON_ARRAY())))
            FROM ewa_lines l WHERE l.eu_no = e.eu_no) AS units,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('gatePassNo', x.gate_pass_no, 'chassisNo', x.chassis_no, 'at', x.released_at, 'truckOrcr', g.truck_orcr))
            FROM ewa_line_chassis x LEFT JOIN gate_passes g ON g.gate_pass_no = x.gate_pass_no WHERE x.eu_no = e.eu_no) AS gatePasses,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', x.extension_id, 'requestedAt', x.requested_at, 'requestedBy', x.requested_by, 'requestedByName', ru.full_name,
                   'reason', x.reason, 'workflowId', x.workflow_id, 'status', x.status, 'decidedAt', x.decided_at, 'decidedBy', x.decided_by, 'decidedByName', du.full_name,
                   'validUntilBefore', x.valid_until_before, 'validUntilAfter', x.valid_until_after))
            FROM ewa_extensions x LEFT JOIN users ru ON ru.user_id = x.requested_by LEFT JOIN users du ON du.user_id = x.decided_by WHERE x.eu_no = e.eu_no) AS extensions,
         (SELECT JSON_OBJECT('workflowId', w.workflow_id, 'step', w.current_step - 1, 'stepLabel', s.label,
                   'approvals', IFNULL((SELECT JSON_ARRAYAGG(JSON_OBJECT('label', s2.label, 'by', IFNULL(u2.full_name, s2.decided_by), 'at', s2.decided_at))
                                          FROM workflow_steps s2 LEFT JOIN users u2 ON u2.user_id = s2.decided_by
                                         WHERE s2.workflow_id = w.workflow_id AND s2.decision = 'Approved'), JSON_ARRAY()))
            FROM workflows w JOIN workflow_steps s ON s.workflow_id = w.workflow_id AND s.step_no = w.current_step
           WHERE w.matrix_code = 'EWA_EXTENSION' AND w.subject_type = 'ewa' AND w.subject_id = e.eu_no AND w.status = 'Pending'
           ORDER BY w.requested_at DESC LIMIT 1) AS extension,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', m.message_id, 'at', m.queued_at, 'channel', m.channel, 'audience', m.audience, 'recipient', m.recipient_label,
                   'recipientName', m.recipient_name, 'to', m.to_address, 'status', m.status, 'resend', m.is_resend))
            FROM message_outbox m WHERE m.entity_type = 'ewa' AND m.entity_id = e.eu_no) AS delivery
    FROM ewas e JOIN clients c ON c.client_code = e.client_code
    LEFT JOIN users cu ON cu.user_id = e.created_by LEFT JOIN users cb ON cb.user_id = e.cancelled_by
   WHERE e.client_code = v_client
     AND (p_status IS NULL OR p_status = '' OR IF(e.status IN ('Active','Partially Used') AND e.valid_until < v_now, 'Expired', e.status) = p_status)
     AND (p_from IS NULL OR fn_manila_date(e.created_at) >= p_from) AND (p_to IS NULL OR fn_manila_date(e.created_at) <= p_to)
     AND (p_q IS NULL OR p_q = '' OR e.eu_no LIKE v_q OR e.driver_license_hash = p_q_licence_hash OR e.truck_plate_no LIKE v_q OR e.trucker LIKE v_q OR e.contract_no LIKE v_q)
   ORDER BY e.created_at DESC, e.eu_no DESC LIMIT v_offset, v_size;

  SELECT COUNT(*) AS total FROM ewas e
   WHERE e.client_code = v_client
     AND (p_status IS NULL OR p_status = '' OR IF(e.status IN ('Active','Partially Used') AND e.valid_until < v_now, 'Expired', e.status) = p_status)
     AND (p_from IS NULL OR fn_manila_date(e.created_at) >= p_from) AND (p_to IS NULL OR fn_manila_date(e.created_at) <= p_to)
     AND (p_q IS NULL OR p_q = '' OR e.eu_no LIKE v_q OR e.driver_license_hash = p_q_licence_hash OR e.truck_plate_no LIKE v_q OR e.trucker LIKE v_q OR e.contract_no LIKE v_q);
END$$

-- GET /portal/ewa/:euNo — RS1 header · RS2 lines · RS3 releases · RS4 extensions (with approval step) · RS5 email log · RS6 history (audit)
CREATE PROCEDURE sp_ewa_get(IN p_user_id VARCHAR(100), IN p_eu_no VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF NOT EXISTS (SELECT 1 FROM ewas WHERE eu_no = p_eu_no AND client_code = v_client) THEN SET o_err_code = 'NOT_FOUND', o_err_msg = 'EWA not found.'; LEAVE proc; END IF;

  SELECT e.eu_no AS euNo, e.client_code AS clientCode, c.client_name AS clientName, e.contract_no AS contractNo, e.branch_code AS branchCode, b.branch_name AS branchName,
         e.trucker, e.truck_plate_no AS truckPlateNo, e.truck_orcr AS truckOrcr, e.driver_name AS driverName, e.driver_license_no AS driverLicenseNo,
         e.expected_pickup_at AS expectedPickupAt, e.remarks, e.status, e.created_via AS createdVia, e.created_by AS createdBy, cu.full_name AS createdByName,
         e.created_at AS createdAt, e.valid_until AS validUntil, e.extension_count AS extensionCount,
         e.cancelled_at AS cancelledAt, cb.full_name AS cancelledByName, e.cancel_reason AS cancelReason, e.expired_lapsed_units AS lapsedUnits,
         (e.status = 'Active' AND NOT EXISTS (SELECT 1 FROM ewa_line_chassis x WHERE x.eu_no = e.eu_no)) AS canCancel,
         (e.status = 'Expired') AS canExtend, 'Asia/Manila (PHT, UTC+8)' AS timeZone
    FROM ewas e JOIN clients c ON c.client_code = e.client_code JOIN branches b ON b.branch_code = e.branch_code
    LEFT JOIN users cu ON cu.user_id = e.created_by LEFT JOIN users cb ON cb.user_id = e.cancelled_by
   WHERE e.eu_no = p_eu_no;
  SELECT l.equipment_type AS equipmentType, t.type_name AS equipmentName, l.qty,
         (SELECT COUNT(*) FROM ewa_line_chassis x WHERE x.eu_no = l.eu_no AND x.equipment_type = l.equipment_type) AS released
    FROM ewa_lines l JOIN equipment_types t ON t.equipment_type = l.equipment_type WHERE l.eu_no = p_eu_no;
  SELECT x.equipment_type AS equipmentType, x.chassis_no AS chassisNo, x.gate_pass_no AS gatePassNo, x.released_at AS releasedAt
    FROM ewa_line_chassis x WHERE x.eu_no = p_eu_no ORDER BY x.released_at;
  SELECT x.extension_id AS id, x.requested_at AS requestedAt, ru.full_name AS requestedByName, x.reason, x.status, x.decided_at AS decidedAt, du.full_name AS decidedByName,
         x.valid_until_before AS validUntilBefore, x.valid_until_after AS validUntilAfter,
         (SELECT s.label FROM workflows w JOIN workflow_steps s ON s.workflow_id = w.workflow_id AND s.step_no = w.current_step
           WHERE w.workflow_id = x.workflow_id AND w.status = 'Pending') AS waitingFor
    FROM ewa_extensions x LEFT JOIN users ru ON ru.user_id = x.requested_by LEFT JOIN users du ON du.user_id = x.decided_by
   WHERE x.eu_no = p_eu_no ORDER BY x.extension_id;
  SELECT queued_at AS at, channel, audience, recipient_label AS recipient, recipient_name AS recipientName, to_address AS `to`, status, sent_at AS sentAt, is_resend AS resend
    FROM message_outbox WHERE entity_type = 'ewa' AND entity_id = p_eu_no ORDER BY message_id;
  SELECT a.event_at AS at, a.action, a.actor, IFNULL(u.full_name, a.actor) AS actorName, a.reason, a.after_json AS detail
    FROM audit_log a LEFT JOIN users u ON u.user_id = a.actor WHERE a.entity_type = 'ewa' AND a.entity_id = p_eu_no ORDER BY a.audit_id;
END$$

-- POST /portal/ewa — p_lines = [{"equipmentType":"20FT_CHASSIS","qty":2}, …]
-- Limits: free units at the branch, and what is left on the contract per type and in total (units on hire + open EWAs count).
-- The contract row is locked so two simultaneous requests cannot both take the last unit of entitlement.
CREATE PROCEDURE sp_ewa_create(IN p_user_id VARCHAR(100), IN p_contract_no VARCHAR(30), IN p_branch_code VARCHAR(10),
  IN p_trucker VARCHAR(150), IN p_truck_plate_no VARCHAR(20), IN p_truck_orcr VARCHAR(40), IN p_driver_name VARCHAR(700), IN p_driver_license_no VARCHAR(700),
  IN p_driver_license_hash CHAR(64), IN p_expected_pickup_at DATETIME(3), IN p_remarks VARCHAR(1000), IN p_lines JSON, IN p_source VARCHAR(200),
  OUT o_eu_no VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_gate JSON; DECLARE v_plate VARCHAR(20); DECLARE v_lic VARCHAR(700); DECLARE v_trucker VARCHAR(150); DECLARE v_driver VARCHAR(700);
  DECLARE v_unit_qty INT; DECLARE v_created DATETIME(3); DECLARE v_valid DATETIME(3); DECLARE v_total INT; DECLARE v_left INT;
  DECLARE v_bad_type VARCHAR(30); DECLARE v_bad_msg VARCHAR(500); DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100);
  DECLARE v_line_count INT; DECLARE v_type_count INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; DROP TEMPORARY TABLE IF EXISTS tmp_ewa_lines; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  SET v_gate = fn_client_gate(v_client, 'PORTAL_EWA');
  IF JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.allowed')) <> 'true' THEN
    SET o_err_code = JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.code')), o_err_msg = JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.reason')); LEAVE proc;
  END IF;

  -- PDPA: driver name and licence arrive encrypted (Node has trimmed, upper-cased and checked the LTO licence format first).
  SET v_trucker = TRIM(IFNULL(p_trucker, '')), v_driver = IFNULL(p_driver_name, ''),
      v_plate = REGEXP_REPLACE(UPPER(TRIM(IFNULL(p_truck_plate_no, ''))), '\\s+', ' '), v_lic = IFNULL(p_driver_license_no, '');
  IF v_trucker = '' OR v_driver = '' OR v_plate = '' OR v_lic = '' THEN
    SET o_err_code = 'MISSING_DRIVER_TRUCK_INFO', o_err_msg = 'Missing driver/truck info: enter the trucker, truck plate no., driver name and driver license no.',
        o_err_fields = JSON_OBJECT();
    IF v_trucker = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.trucker', 'Required'); END IF;
    IF v_plate = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.truckPlateNo', 'Required'); END IF;
    IF v_driver = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.driverName', 'Required'); END IF;
    IF v_lic = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.driverLicenseNo', 'Required'); END IF;
    LEAVE proc;
  END IF;
  SET o_err_fields = JSON_OBJECT();
  IF NOT REGEXP_LIKE(v_plate, '^[A-Z]{2,3} ?[0-9]{3,4}$', 'c') THEN SET o_err_fields = JSON_SET(o_err_fields, '$.truckPlateNo', 'Use the LTO format, e.g. NAB 5678'); END IF;
  IF v_lic NOT LIKE 'enc:%' OR v_driver NOT LIKE 'enc:%' OR p_driver_license_hash IS NULL THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.driverLicenseNo', 'Not encrypted by the backend');   -- defence: plain personal data is never stored
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the truck plate and driver license format.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;
  IF CHAR_LENGTH(IFNULL(p_remarks, '')) > 300 THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Remarks are limited to 300 characters.', o_err_fields = JSON_OBJECT('remarks', 'Max 300 characters'); LEAVE proc;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM branches WHERE branch_code = p_branch_code AND is_head_office = 0 AND is_active = 1) THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Choose a pickup branch.', o_err_fields = JSON_OBJECT('branchCode', 'Not a pickup branch'); LEAVE proc;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM client_branch_access WHERE client_code = v_client AND branch_code = p_branch_code) THEN
    SET o_err_code = 'ELIGIBILITY', o_err_msg = 'Pickup branch is not in your CWS branch access.', o_err_fields = JSON_OBJECT('branchCode', 'Branch not allowed'); LEAVE proc;
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_ewa_lines;
  CREATE TEMPORARY TABLE tmp_ewa_lines (equipment_type VARCHAR(30) NOT NULL, qty DECIMAL(12,2) NULL);
  INSERT INTO tmp_ewa_lines SELECT j.t, j.q FROM JSON_TABLE(IFNULL(p_lines, JSON_ARRAY()), '$[*]' COLUMNS (t VARCHAR(30) PATH '$.equipmentType', q DECIMAL(12,2) PATH '$.qty')) j;
  -- (a TEMPORARY table may be read only once per statement → counts into variables)
  SELECT COUNT(*), COUNT(DISTINCT equipment_type) INTO v_line_count, v_type_count FROM tmp_ewa_lines;
  IF v_line_count = 0 THEN
    DROP TEMPORARY TABLE tmp_ewa_lines; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Add at least one equipment type.', o_err_fields = JSON_OBJECT('units', 'Required'); LEAVE proc;
  END IF;
  IF v_type_count <> v_line_count THEN
    DROP TEMPORARY TABLE tmp_ewa_lines; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Each equipment type can appear once — change its quantity instead.', o_err_fields = JSON_OBJECT('units', 'Duplicate type'); LEAVE proc;
  END IF;
  IF EXISTS (SELECT 1 FROM tmp_ewa_lines WHERE qty IS NULL OR qty < 1 OR qty <> FLOOR(qty)) THEN
    DROP TEMPORARY TABLE tmp_ewa_lines; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Quantity must be a whole number of at least 1.', o_err_fields = JSON_OBJECT('units', 'Whole number, at least 1'); LEAVE proc;
  END IF;

  START TRANSACTION;
  SELECT unit_qty INTO v_unit_qty FROM contracts WHERE contract_no = p_contract_no AND client_code = v_client AND status = 'Active' FOR UPDATE;
  IF v_unit_qty IS NULL THEN
    ROLLBACK; DROP TEMPORARY TABLE tmp_ewa_lines; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Select an active contract for this client.', o_err_fields = JSON_OBJECT('contractNo', 'No active contract'); LEAVE proc;
  END IF;
  -- Lock the free units at the branch for the types requested (consistent availability count).
  SELECT COUNT(*) INTO v_total FROM chassis WHERE branch_code = p_branch_code AND status = 'Available'
     AND chassis_type IN (SELECT equipment_type FROM tmp_ewa_lines) FOR UPDATE;

  SELECT l.equipment_type,
         CASE WHEN r.equipment_type IS NULL THEN CONCAT(IFNULL(t.type_name, l.equipment_type), ' is not on contract ', p_contract_no, '.')
              WHEN l.qty > fn_available_units(p_branch_code, l.equipment_type) THEN CONCAT('Only ', fn_available_units(p_branch_code, l.equipment_type), ' unit(s) of ', t.type_name, ' available at ', p_branch_code, '.')
              WHEN l.qty > fn_type_remaining(p_contract_no, l.equipment_type) THEN CONCAT('Contract ', p_contract_no, ' allows ', fn_type_remaining(p_contract_no, l.equipment_type), ' more ', t.type_name,
                   ' unit(s) (', IF(r.entitled_qty IS NULL, '', CONCAT(r.entitled_qty, ' entitled, ')), fn_contract_on_hire(p_contract_no, l.equipment_type), ' on hire, ',
                   fn_contract_pending(p_contract_no, l.equipment_type), ' on open EWAs).') END
    INTO v_bad_type, v_bad_msg
    FROM tmp_ewa_lines l LEFT JOIN contract_rates r ON r.contract_no = p_contract_no AND r.equipment_type = l.equipment_type
    LEFT JOIN equipment_types t ON t.equipment_type = l.equipment_type
   WHERE r.equipment_type IS NULL OR l.qty > fn_available_units(p_branch_code, l.equipment_type) OR l.qty > fn_type_remaining(p_contract_no, l.equipment_type)
   LIMIT 1;
  IF v_bad_type IS NOT NULL THEN
    ROLLBACK; DROP TEMPORARY TABLE tmp_ewa_lines;
    SET o_err_code = IF(v_bad_msg LIKE 'Contract %', 'ENTITLEMENT_EXCEEDED', 'VALIDATION_FAILED'), o_err_msg = v_bad_msg, o_err_fields = JSON_OBJECT('units', v_bad_msg); LEAVE proc;
  END IF;
  SET v_left = fn_contract_remaining(p_contract_no);
  IF (SELECT SUM(qty) FROM tmp_ewa_lines) > v_left THEN
    ROLLBACK; DROP TEMPORARY TABLE tmp_ewa_lines;
    SET o_err_code = 'ENTITLEMENT_EXCEEDED', o_err_msg = CONCAT('Contract ', p_contract_no, ' covers ', v_unit_qty, ' units; ', fn_contract_on_hire(p_contract_no, NULL), ' are on hire and ',
        fn_contract_pending(p_contract_no, NULL), ' are on open EWAs, so ', v_left, ' more can be requested.'), o_err_fields = JSON_OBJECT('units', CONCAT(v_left, ' left on the contract')); LEAVE proc;
  END IF;

  -- One clock reading for created and valid-until, so the validity is exactly the configured hours (BR-06).
  SET v_created = UTC_TIMESTAMP(3), v_valid = v_created + INTERVAL fn_setting_num('gat.ewa_validity_hours', 24) HOUR;
  IF p_expected_pickup_at IS NOT NULL AND (p_expected_pickup_at > v_valid OR p_expected_pickup_at < v_created - INTERVAL 1 HOUR) THEN
    ROLLBACK; DROP TEMPORARY TABLE tmp_ewa_lines;
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'The expected pickup must fall within the EWA validity.', o_err_fields = JSON_OBJECT('expectedPickupAt', 'Within the next 24 hours'); LEAVE proc;
  END IF;

  CALL sp_next_number('EU', 'EU-', 6, o_eu_no);
  INSERT INTO ewas (eu_no, client_code, contract_no, branch_code, trucker, truck_plate_no, truck_orcr, driver_name, driver_license_no, driver_license_hash, expected_pickup_at, remarks,
                    status, created_via, created_by, created_at, valid_until)
  VALUES (o_eu_no, v_client, p_contract_no, p_branch_code, v_trucker, v_plate, NULLIF(TRIM(p_truck_orcr), ''), v_driver, v_lic, p_driver_license_hash, p_expected_pickup_at, NULLIF(TRIM(p_remarks), ''),
          'Active', 'Portal', p_user_id, v_created, v_valid);
  INSERT INTO ewa_lines (eu_no, equipment_type, qty) SELECT o_eu_no, equipment_type, qty FROM tmp_ewa_lines;
  DROP TEMPORARY TABLE tmp_ewa_lines;

  CALL sp_ewa_queue_delivery(o_eu_no, 0);
  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  CALL sp_notify_roles(JSON_ARRAY('BRANCH_GENERALIST'), p_branch_code, 'ewa.created', CONCAT('EWA ', o_eu_no, ' created — ', v_cname),
       CONCAT('Branch ', p_branch_code, ' · truck ', v_plate, ' · valid until ', DATE_FORMAT(v_valid + INTERVAL 8 HOUR, '%d-%b-%Y %H:%i'), ' PHT'), '/gate/ewa');
  CALL sp_notify_user(v_ae, 'ewa.created', CONCAT('EWA ', o_eu_no, ' created — ', v_cname), CONCAT('Branch ', p_branch_code, ' · truck ', v_plate), '/gate/ewa');
  CALL sp_notify_client_users(v_client, 'ewa.created.portal', CONCAT('EWA ', o_eu_no, ' created'),
       CONCAT(p_branch_code, ' · ', v_plate, ' · valid until ', DATE_FORMAT(v_valid + INTERVAL 8 HOUR, '%d-%b-%Y %H:%i'), ' PHT'), CONCAT('/client/ewa?open=', o_eu_no));
  CALL sp_audit_write(p_user_id, 'CLIENT', 'ewa.created', 'ewa', o_eu_no, p_branch_code, NULL,
       JSON_OBJECT('contractNo', p_contract_no, 'branchCode', p_branch_code, 'driver', v_driver, 'plate', v_plate, 'lines', p_lines, 'validUntil', v_valid), NULL, p_source);
  COMMIT;
  CALL sp_ewa_get(p_user_id, o_eu_no, o_err_code, o_err_msg);
END$$

-- POST /portal/ewa/:euNo/cancel — client may cancel while Active and nothing has been released (proposed rule).
CREATE PROCEDURE sp_ewa_cancel(IN p_user_id VARCHAR(100), IN p_eu_no VARCHAR(20), IN p_reason VARCHAR(1000), IN p_source VARCHAR(200),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_valid DATETIME(3); DECLARE v_branch VARCHAR(10); DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  START TRANSACTION;
  SELECT status, valid_until, branch_code INTO v_status, v_valid, v_branch FROM ewas WHERE eu_no = p_eu_no AND client_code = v_client FOR UPDATE;
  IF v_status IS NULL THEN ROLLBACK; SET o_err_code = 'NOT_FOUND', o_err_msg = 'EWA not found.'; LEAVE proc; END IF;
  IF v_status IN ('Active','Partially Used') AND v_valid < UTC_TIMESTAMP(3) THEN SET v_status = 'Expired'; END IF;   -- expired but job not yet run
  IF v_status = 'Partially Used' OR EXISTS (SELECT 1 FROM ewa_line_chassis WHERE eu_no = p_eu_no) THEN
    ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_eu_no, ' has units already released — call the ', v_branch, ' branch to cancel the rest.'); LEAVE proc;
  END IF;
  IF v_status <> 'Active' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_eu_no, ' is ', LOWER(v_status), ' and cannot be cancelled.'); LEAVE proc; END IF;
  IF IFNULL(TRIM(p_reason), '') = '' THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'A cancellation reason is required.', o_err_fields = JSON_OBJECT('reason', 'Required'); LEAVE proc; END IF;
  UPDATE ewas SET status = 'Cancelled', cancelled_at = UTC_TIMESTAMP(3), cancelled_by = p_user_id, cancel_reason = TRIM(p_reason), row_version = row_version + 1 WHERE eu_no = p_eu_no;
  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  CALL sp_notify_roles(JSON_ARRAY('BRANCH_GENERALIST'), v_branch, 'ewa.cancelled', CONCAT('EWA ', p_eu_no, ' cancelled by the client'), CONCAT(v_cname, ' · ', v_branch, ' · ', TRIM(p_reason)), '/gate/ewa');
  CALL sp_notify_user(v_ae, 'ewa.cancelled', CONCAT('EWA ', p_eu_no, ' cancelled by the client'), CONCAT(v_cname, ' · ', v_branch, ' · ', TRIM(p_reason)), '/gate/ewa');
  CALL sp_audit_write(p_user_id, 'CLIENT', 'ewa.cancelled', 'ewa', p_eu_no, v_branch, JSON_OBJECT('status', 'Active'), JSON_OBJECT('status', 'Cancelled'), TRIM(p_reason), p_source);
  COMMIT;
END$$

-- POST /portal/ewa/:euNo/extension — only an Expired EWA; manager approval then IT revalidation (BR-06).
-- valid_until changes only after both approve (done by the staff approval flow).
CREATE PROCEDURE sp_ewa_request_extension(IN p_user_id VARCHAR(100), IN p_eu_no VARCHAR(20), IN p_reason VARCHAR(1000), IN p_source VARCHAR(200),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_valid DATETIME(3); DECLARE v_branch VARCHAR(10); DECLARE v_gate JSON; DECLARE v_wf VARCHAR(20);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  START TRANSACTION;
  SELECT status, valid_until, branch_code INTO v_status, v_valid, v_branch FROM ewas WHERE eu_no = p_eu_no AND client_code = v_client FOR UPDATE;
  IF v_status IS NULL THEN ROLLBACK; SET o_err_code = 'NOT_FOUND', o_err_msg = 'EWA not found.'; LEAVE proc; END IF;
  IF v_status IN ('Active','Partially Used') AND v_valid < UTC_TIMESTAMP(3) THEN SET v_status = 'Expired'; END IF;
  IF v_status <> 'Expired' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = 'Only expired EWAs can be extended.'; LEAVE proc; END IF;
  IF IFNULL(TRIM(p_reason), '') = '' THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'A reason for the extension is required.', o_err_fields = JSON_OBJECT('reason', 'Required'); LEAVE proc; END IF;
  SET v_gate = fn_client_gate(v_client, 'EWA_CREATE');
  IF JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.allowed')) <> 'true' THEN
    ROLLBACK; SET o_err_code = JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.code')), o_err_msg = JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.reason')); LEAVE proc;
  END IF;
  CALL sp_workflow_start('EWA_EXTENSION', CONCAT('EWA extension — ', p_eu_no), 'ewa', p_eu_no, NULL, v_branch, p_user_id,
       JSON_ARRAY(JSON_OBJECT('label', 'Manager approval', 'roles', JSON_ARRAY('DYM','REGIONAL_MANAGER','OPS_MANAGER')),
                  JSON_OBJECT('label', 'IT / authorised revalidation', 'roles', JSON_ARRAY('SYS_ADMIN'))), v_wf);
  UPDATE ewas SET status = 'Extension Pending', row_version = row_version + 1 WHERE eu_no = p_eu_no;
  INSERT INTO ewa_extensions (eu_no, requested_by, reason, workflow_id, status, valid_until_before) VALUES (p_eu_no, p_user_id, TRIM(p_reason), v_wf, 'Pending', v_valid);
  CALL sp_audit_write(p_user_id, 'CLIENT', 'ewa.extension_requested', 'ewa', p_eu_no, v_branch, JSON_OBJECT('status', 'Expired'), JSON_OBJECT('status', 'Extension Pending', 'workflow', v_wf), TRIM(p_reason), p_source);
  COMMIT;
END$$

-- POST /portal/ewa/:euNo/resend-email — the same recipients again; each send logged.
CREATE PROCEDURE sp_ewa_resend_email(IN p_user_id VARCHAR(100), IN p_eu_no VARCHAR(20), IN p_source VARCHAR(200), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_valid DATETIME(3); DECLARE v_first BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT status, valid_until INTO v_status, v_valid FROM ewas WHERE eu_no = p_eu_no AND client_code = v_client;
  IF v_status IS NULL THEN SET o_err_code = 'NOT_FOUND', o_err_msg = 'EWA not found.'; LEAVE proc; END IF;
  IF v_status NOT IN ('Active','Partially Used') OR v_valid < UTC_TIMESTAMP(3) THEN
    SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_eu_no, ' is ', LOWER(IF(v_valid < UTC_TIMESTAMP(3) AND v_status IN ('Active','Partially Used'), 'Expired', v_status)), ' — there is nothing to resend.'); LEAVE proc;
  END IF;
  START TRANSACTION;
  SELECT IFNULL(MAX(message_id), 0) INTO v_first FROM message_outbox;
  CALL sp_ewa_queue_delivery(p_eu_no, 1);
  CALL sp_audit_write(p_user_id, 'CLIENT', 'ewa.email_resent', 'ewa', p_eu_no, NULL, NULL,
       (SELECT JSON_OBJECT('recipients', JSON_ARRAYAGG(to_address)) FROM message_outbox WHERE entity_type = 'ewa' AND entity_id = p_eu_no AND message_id > v_first), NULL, p_source);
  COMMIT;
  SELECT queued_at AS at, channel, audience, recipient_label AS recipient, recipient_name AS recipientName, to_address AS `to`, status, is_resend AS resend
    FROM message_outbox WHERE entity_type = 'ewa' AND entity_id = p_eu_no AND message_id > v_first ORDER BY message_id;
END$$

DELIMITER ;
