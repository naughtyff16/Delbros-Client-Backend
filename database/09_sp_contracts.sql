-- =====================================================================================================
-- 09_sp_contracts.sql : Portal Contracts — every contract with entitlement, lock-in & BR-15 fee, rate history
--                       (BR-18) and rate card, minimum billing days, renewal notices, branches covered vs activity,
--                       requests and bonds; renewal / amendment / termination request
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_portal_contracts;
DROP PROCEDURE IF EXISTS sp_contract_request_create;

DELIMITER $$

-- GET /portal/contracts
-- RS1 contracts · RS2 entitlement & rates per type · RS3 rate history (versions with lines) · RS4 units on hire
-- RS5 branches covered / activity · RS6 requests · RS7 bonds with outcome · RS8 contract history
CREATE PROCEDURE sp_portal_contracts(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_today DATE DEFAULT fn_manila_today(); DECLARE v_cap INT DEFAULT fn_setting_num('clt.pretermination_cap_days', 30);
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  -- RS1
  SELECT k.contract_no AS contractNo, k.contract_type AS contractType, k.contract_class AS class, k.status, k.effective_date AS effectiveDate, k.expiry_date AS expiryDate,
         k.unit_qty AS unitQty, k.region AS regionName, k.payment_method AS paymentMethod, k.billing_cycle AS billingCycle, k.credit_term_days AS creditTermDays,
         k.cash_deposit AS cashDeposit, k.lock_in_months AS lockInMonths, fn_min_billing_days(k.contract_no) AS minBillingDays,
         k.penalty_non_return AS penaltyNonReturn, k.penalty_deferred_check AS penaltyDeferredCheck, k.penalty_late_interest_pct AS penaltyLateInterestPct,
         k.penalty_dishonored_check AS penaltyDishonoredCheck, k.version_no AS version, k.renewal_of AS renewalOf, k.renewed_to AS renewedTo,
         k.renewal_state AS renewalState, k.renewal_date AS renewalDate, k.renewal_note AS renewalNote, k.termination_reason AS terminationReason, k.termination_date AS terminationDate,
         IF(k.contract_type = 'SPL' AND k.expiry_date IS NULL, 'No contractual expiry (open-ended)', NULL) AS expiryNote,
         JSON_MERGE_PATCH(fn_pretermination(k.effective_date, k.lock_in_months, v_today, dt.daily_total, v_cap),
                          JSON_OBJECT('capDays', v_cap, 'dailyTotal', dt.daily_total, 'unitsOnHire', dt.units)) AS preTermination,
         IF(k.status = 'Active' AND k.expiry_date IS NOT NULL,
            JSON_ARRAY(JSON_OBJECT('monthsBefore', 3, 'date', k.expiry_date - INTERVAL 3 MONTH, 'sent', k.expiry_date - INTERVAL 3 MONTH <= v_today),
                       JSON_OBJECT('monthsBefore', 2, 'date', k.expiry_date - INTERVAL 2 MONTH, 'sent', k.expiry_date - INTERVAL 2 MONTH <= v_today),
                       JSON_OBJECT('monthsBefore', 1, 'date', k.expiry_date - INTERVAL 1 MONTH, 'sent', k.expiry_date - INTERVAL 1 MONTH <= v_today)), JSON_ARRAY()) AS renewalNotices,
         IF(k.status = 'Active', JSON_OBJECT('unitQty', k.unit_qty, 'onHire', fn_contract_on_hire(k.contract_no, NULL), 'pending', fn_contract_pending(k.contract_no, NULL),
                                             'remaining', fn_contract_remaining(k.contract_no)), NULL) AS entitlementTotals,
         (SELECT IFNULL(SUM(b.amount), 0) FROM cash_bonds b WHERE b.contract_no = k.contract_no AND b.status IN ('Held','Withdrawal Pending')) AS bondHeld,
         (SELECT JSON_OBJECT('firstName', p.first_name, 'lastName', p.last_name, 'email', p.email, 'phone', p.phone) FROM client_contacts p
           WHERE p.contact_id = k.signatory_contact_id OR (k.signatory_contact_id IS NULL AND p.client_code = k.client_code AND p.is_signatory = 1) ORDER BY (p.contact_id = k.signatory_contact_id) DESC LIMIT 1) AS signatory,
         (SELECT w.minimum_balance FROM ewallets w WHERE w.client_code = k.client_code) AS ewalletMinimum
    FROM contracts k
    JOIN (SELECT k2.contract_no, COUNT(ch.chassis_no) AS units, IFNULL(SUM(r.daily_rate), 0) AS daily_total
            FROM contracts k2 LEFT JOIN chassis ch ON ch.current_contract_no = k2.contract_no AND ch.status IN ('On Hire','Rescue')
            LEFT JOIN contract_rates r ON r.contract_no = k2.contract_no AND r.equipment_type = ch.chassis_type
           WHERE k2.client_code = v_client GROUP BY k2.contract_no) dt ON dt.contract_no = k.contract_no
   WHERE k.client_code = v_client
   ORDER BY (k.status = 'Active') DESC, k.effective_date DESC;

  -- RS2 entitlement per type (entitled: NULL = no per-type cap; 0 = not entitled, on request)
  SELECT r.contract_no AS contractNo, r.equipment_type AS equipmentType, t.type_name AS equipmentName, r.daily_rate AS dailyRate, r.indemnity,
         (SELECT rc.daily_rate FROM rate_cards rc WHERE rc.equipment_type = r.equipment_type AND rc.contract_type = k.contract_type
             AND rc.valid_from <= v_today AND (rc.valid_to IS NULL OR rc.valid_to >= v_today) ORDER BY rc.valid_from DESC LIMIT 1) AS rateCard,
         IF(k.entitlement_by_type = 1 OR IFNULL(r.entitled_qty, 0) > 0, IFNULL(r.entitled_qty, 0), NULL) AS entitled,
         fn_contract_on_hire(k.contract_no, r.equipment_type) AS onHire,
         IF(k.status = 'Active', fn_contract_pending(k.contract_no, r.equipment_type), 0) AS pending,
         IF(k.status = 'Active', fn_type_remaining(k.contract_no, r.equipment_type), NULL) AS remaining
    FROM contract_rates r JOIN contracts k ON k.contract_no = r.contract_no JOIN equipment_types t ON t.equipment_type = r.equipment_type
   WHERE k.client_code = v_client ORDER BY r.contract_no, t.sort_order;

  -- RS3 rate history
  SELECT v.contract_no AS contractNo, v.version_no AS version, v.valid_from AS validFrom, v.valid_to AS validTo, v.reason,
         IFNULL((SELECT JSON_ARRAYAGG(JSON_OBJECT('equipmentType', l.equipment_type, 'dailyRate', l.daily_rate)) FROM contract_rate_version_lines l
           WHERE l.contract_no = v.contract_no AND l.version_no = v.version_no), JSON_ARRAY()) AS rates
    FROM contract_rate_versions v JOIN contracts k ON k.contract_no = v.contract_no WHERE k.client_code = v_client ORDER BY v.contract_no, v.version_no;

  -- RS4 units on hire per contract (branch = release branch)
  SELECT ch.current_contract_no AS contractNo, ch.chassis_no AS chassisNo, ch.chassis_type AS chassisType,
         IFNULL((SELECT g.branch_code FROM gate_passes g WHERE g.gate_pass_no = ch.current_gate_pass_no), ch.branch_code) AS branchCode, IFNULL(r.daily_rate, 0) AS dailyRate
    FROM chassis ch JOIN contracts k ON k.contract_no = ch.current_contract_no
    LEFT JOIN contract_rates r ON r.contract_no = ch.current_contract_no AND r.equipment_type = ch.chassis_type
   WHERE k.client_code = v_client AND ch.status IN ('On Hire','Rescue');

  -- RS5 branches: every covered branch (active contracts, zeros included) plus any branch with activity outside the list
  SELECT x.contract_no AS contractNo, x.branch_code AS code, b.branch_name AS name,
         (SELECT COUNT(*) FROM gate_passes g WHERE g.contract_no = x.contract_no AND g.direction = 'OUT' AND g.branch_code = x.branch_code) AS releases,
         (SELECT COUNT(*) FROM ewas e WHERE e.contract_no = x.contract_no AND e.branch_code = x.branch_code) AS ewas,
         (SELECT COUNT(*) FROM chassis ch JOIN gate_passes g ON g.gate_pass_no = ch.current_gate_pass_no
           WHERE ch.current_contract_no = x.contract_no AND ch.status IN ('On Hire','Rescue') AND g.branch_code = x.branch_code) AS onHire,
         EXISTS (SELECT 1 FROM client_branch_access a WHERE a.client_code = v_client AND a.branch_code = x.branch_code) AS covered
    FROM (SELECT k.contract_no, a.branch_code FROM contracts k JOIN client_branch_access a ON a.client_code = k.client_code WHERE k.client_code = v_client AND k.status = 'Active'
          UNION SELECT g.contract_no, g.branch_code FROM gate_passes g JOIN contracts k ON k.contract_no = g.contract_no WHERE k.client_code = v_client AND g.direction = 'OUT'
          UNION SELECT e.contract_no, e.branch_code FROM ewas e WHERE e.client_code = v_client) x
    JOIN branches b ON b.branch_code = x.branch_code
   ORDER BY x.contract_no, b.branch_name;

  -- RS6 requests
  SELECT q.request_id AS id, q.contract_no AS contractNo, q.kind, q.details, q.term_months AS termMonths, q.change_area AS changeArea, q.effective_date AS effectiveDate,
         q.fee_estimate AS feeEstimate, q.status, q.submitted_at AS submittedAt, su.full_name AS submittedByName, q.decided_at AS decidedAt,
         IFNULL(du.full_name, q.decided_by) AS decidedByName, q.decision_note AS decisionNote
    FROM contract_requests q LEFT JOIN users su ON su.user_id = q.submitted_by LEFT JOIN users du ON du.user_id = q.decided_by
   WHERE q.client_code = v_client ORDER BY q.submitted_at DESC;

  -- RS7 bonds per contract with what happened to them
  SELECT b.contract_no AS contractNo, b.bond_id AS id, b.amount, b.date_received AS dateReceived, b.receipt_ref AS receiptRef, b.status,
         IF(b.outcome_kind IS NULL, NULL, JSON_OBJECT('kind', b.outcome_kind, 'at', b.outcome_at, 'amount', b.outcome_amount, 'reference', b.outcome_reference,
                                                      'note', b.outcome_note, 'toContractNo', b.outcome_to_contract)) AS outcome,
         (SELECT JSON_OBJECT('method', w.refund_method, 'date', w.refund_date, 'reference', w.refund_reference) FROM cash_bond_withdrawals w
           WHERE w.bond_id = b.bond_id AND w.status = 'Refunded' ORDER BY w.refund_date DESC LIMIT 1) AS refund
    FROM cash_bonds b WHERE b.client_code = v_client AND b.contract_no IS NOT NULL;

  -- RS8 history (lifecycle, renewal notices)
  SELECT e.contract_no AS contractNo, e.status_label AS status, e.event_at AS at, IFNULL(u.full_name, e.event_by) AS byName, e.note
    FROM contract_events e JOIN contracts k ON k.contract_no = e.contract_no LEFT JOIN users u ON u.user_id = e.event_by
   WHERE k.client_code = v_client ORDER BY e.contract_no, e.event_at;
END$$

-- POST /portal/contracts/:contractNo/requests — Renewal (term 1–60 months) · Amendment (change area) · Termination (date ≥ today, BR-15 estimate)
-- One open request per kind. The Account Executive and the Sales Director are told.
CREATE PROCEDURE sp_contract_request_create(IN p_user_id VARCHAR(100), IN p_contract_no VARCHAR(30), IN p_kind VARCHAR(20), IN p_details VARCHAR(2000),
  IN p_term_months INT, IN p_change_area VARCHAR(100), IN p_effective_date DATE, IN p_source VARCHAR(200),
  OUT o_request_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_eff DATE; DECLARE v_lock INT; DECLARE v_daily DECIMAL(15,2); DECLARE v_fee DECIMAL(15,2) DEFAULT NULL;
  DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100); DECLARE v_body TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF p_kind NOT IN ('Renewal','Amendment','Termination') THEN SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Choose renewal, amendment or termination.', o_err_fields = JSON_OBJECT('kind', 'Required'); LEAVE proc; END IF;

  START TRANSACTION;
  SELECT status, effective_date, lock_in_months INTO v_status, v_eff, v_lock FROM contracts WHERE contract_no = p_contract_no AND client_code = v_client FOR UPDATE;
  IF v_status IS NULL THEN ROLLBACK; SET o_err_code = 'NOT_FOUND', o_err_msg = 'Contract not found.'; LEAVE proc; END IF;
  IF v_status <> 'Active' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_contract_no, ' is ', LOWER(v_status), ' — only an active contract can be renewed, amended or terminated.'); LEAVE proc; END IF;
  IF EXISTS (SELECT 1 FROM contract_requests WHERE contract_no = p_contract_no AND kind = p_kind AND status IN ('Submitted','Under review')) THEN
    ROLLBACK; SET o_err_code = 'DUPLICATE', o_err_msg = CONCAT('A ', LOWER(p_kind), ' request for ', p_contract_no, ' is already open.'); LEAVE proc;
  END IF;
  SET o_err_fields = JSON_OBJECT();
  IF CHAR_LENGTH(TRIM(IFNULL(p_details, ''))) < 10 THEN SET o_err_fields = JSON_SET(o_err_fields, '$.details', 'Tell us what you need (at least 10 characters)'); END IF;
  IF p_kind = 'Renewal' AND (p_term_months IS NULL OR p_term_months < 1 OR p_term_months > 60) THEN SET o_err_fields = JSON_SET(o_err_fields, '$.termMonths', 'Whole months, 1 to 60'); END IF;
  IF p_kind = 'Amendment' AND IFNULL(TRIM(p_change_area), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.changeArea', 'Required'); END IF;
  IF p_kind = 'Termination' THEN
    IF p_effective_date IS NULL THEN SET o_err_fields = JSON_SET(o_err_fields, '$.effectiveDate', 'Required');
    ELSEIF p_effective_date < fn_manila_today() THEN SET o_err_fields = JSON_SET(o_err_fields, '$.effectiveDate', 'Today or later'); END IF;
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;

  IF p_kind = 'Termination' THEN
    SELECT IFNULL(SUM(r.daily_rate), 0) INTO v_daily FROM chassis ch JOIN contract_rates r ON r.contract_no = ch.current_contract_no AND r.equipment_type = ch.chassis_type
     WHERE ch.current_contract_no = p_contract_no AND ch.status IN ('On Hire','Rescue');
    SET v_fee = JSON_EXTRACT(fn_pretermination(v_eff, v_lock, p_effective_date, v_daily, fn_setting_num('clt.pretermination_cap_days', 30)), '$.fee');
  END IF;
  CALL sp_next_number('CRQ', 'CRQ-', 6, o_request_id);
  INSERT INTO contract_requests (request_id, client_code, contract_no, kind, details, term_months, change_area, effective_date, fee_estimate, status, submitted_by)
  VALUES (o_request_id, v_client, p_contract_no, p_kind, TRIM(p_details), IF(p_kind = 'Renewal', p_term_months, NULL), IF(p_kind = 'Amendment', TRIM(p_change_area), NULL),
          IF(p_kind = 'Termination', p_effective_date, NULL), v_fee, 'Submitted', p_user_id);
  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  SET v_body = CONCAT(p_contract_no, ' · ', TRIM(p_details));
  CALL sp_notify_user(v_ae, 'contract.request', CONCAT('Contract ', LOWER(p_kind), ' request ', o_request_id, ': ', v_cname), v_body, '/contracts');
  CALL sp_notify_roles(JSON_ARRAY('SALES_DIRECTOR'), NULL, 'contract.request', CONCAT('Contract ', LOWER(p_kind), ' request ', o_request_id, ': ', v_cname), v_body, '/contracts');
  INSERT INTO contract_events (contract_no, status_label, event_by, note) VALUES (p_contract_no, CONCAT(p_kind, ' requested'), p_user_id, CONCAT(o_request_id, ' · ', TRIM(p_details)));
  CALL sp_audit_write(p_user_id, 'CLIENT', 'portal.contract_request', 'contract', p_contract_no, NULL, NULL,
       JSON_OBJECT('id', o_request_id, 'kind', p_kind, 'termMonths', p_term_months, 'changeArea', p_change_area, 'effectiveDate', p_effective_date, 'feeEstimate', v_fee), NULL, p_source);
  COMMIT;
  SELECT request_id AS id, contract_no AS contractNo, kind, details, term_months AS termMonths, change_area AS changeArea, effective_date AS effectiveDate,
         fee_estimate AS feeEstimate, status, submitted_at AS submittedAt FROM contract_requests WHERE request_id = o_request_id;
END$$

DELIMITER ;
