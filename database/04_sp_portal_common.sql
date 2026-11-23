-- =====================================================================================================
-- 04_sp_portal_common.sql : reference data, files (S3 metadata), client dashboard, notifications,
--                           feedback / rating, return request
-- Every procedure takes p_user_id (from the server session — never from the request body) and checks the realm.
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_ref_all;
DROP PROCEDURE IF EXISTS sp_file_register;
DROP PROCEDURE IF EXISTS sp_file_confirm_upload;
DROP PROCEDURE IF EXISTS sp_file_get;
DROP PROCEDURE IF EXISTS sp_file_scan_result;
DROP PROCEDURE IF EXISTS sp_portal_dashboard;
DROP PROCEDURE IF EXISTS sp_portal_notifications_list;
DROP PROCEDURE IF EXISTS sp_portal_notifications_mark_read;
DROP PROCEDURE IF EXISTS sp_portal_feedback_submit;
DROP PROCEDURE IF EXISTS sp_portal_feedback_list;
DROP PROCEDURE IF EXISTS sp_portal_return_request;

DELIMITER $$

-- GET /ref — reference data for any signed-in portal user. Does NOT return staff users or other clients.
CREATE PROCEDURE sp_ref_all(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  -- p_user_id NULL = not signed in (e.g. the "Request portal access" form needs the branch list): same public reference data.
  IF p_user_id IS NOT NULL THEN
    CALL sp_ctx_user(p_user_id, NULL, v_realm, v_client, v_vendor, v_name, v_email, v_ok);
    IF v_ok = 0 OR v_realm = 'INTERNAL' THEN SET o_err_code = 'UNAUTHENTICATED', o_err_msg = 'Your session has ended. Please sign in again.'; LEAVE proc; END IF;
  END IF;
  SELECT branch_code AS code, branch_name AS name, region, region_group AS regionGroup, is_head_office AS isHeadOffice, billing_entity AS billingEntity,
         gate_pass_prefix AS gatePassPrefix, issues_gate_passes AS issuesGatePasses
    FROM branches WHERE is_active = 1 ORDER BY branch_name;
  SELECT equipment_type AS code, type_name AS name, sort_order AS sort FROM equipment_types WHERE is_active = 1 ORDER BY sort_order;
  SELECT setting_key AS `key`, setting_value AS value, value_type AS type FROM system_settings WHERE is_public = 1;
END$$

-- ── Files (stored on the EC2 server) ────────────────────────────────────────────────────────────────────────────────
-- POST /files: Node creates the UUID + storage path, calls this to validate and record; the browser then PUTs the file to the API.
-- p_user_id NULL = anonymous upload from "Request portal access" (purpose ACCESS_DOC only).
CREATE PROCEDURE sp_file_register(IN p_user_id VARCHAR(100), IN p_file_id CHAR(36), IN p_storage_path VARCHAR(500),
  IN p_original_name VARCHAR(255), IN p_content_type VARCHAR(100), IN p_size_bytes BIGINT, IN p_purpose VARCHAR(40),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT DEFAULT 0;
  DECLARE v_max_mb DECIMAL(18,6) DEFAULT fn_setting_num(CONCAT('files.max_mb.', p_purpose), fn_setting_num('files.max_mb', 5));
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  IF p_user_id IS NULL THEN
    IF p_purpose <> 'ACCESS_DOC' THEN SET o_err_code = 'UNAUTHENTICATED', o_err_msg = 'Your session has ended. Please sign in again.'; LEAVE proc; END IF;
  ELSE
    CALL sp_ctx_user(p_user_id, NULL, v_realm, v_client, v_vendor, v_name, v_email, v_ok);
    IF v_ok = 0 THEN SET o_err_code = 'UNAUTHENTICATED', o_err_msg = 'Your session has ended. Please sign in again.'; LEAVE proc; END IF;
    IF (p_purpose = 'VENDOR_INVOICE' AND v_realm <> 'VENDOR_PORTAL')
       OR (p_purpose IN ('TOPUP_PROOF','PAYMENT_PROOF','DISPUTE_ATTACHMENT','RESCUE_PHOTO') AND v_realm <> 'CLIENT_PORTAL') THEN
      SET o_err_code = 'FORBIDDEN', o_err_msg = 'This upload is not available in your portal.'; LEAVE proc;
    END IF;
  END IF;
  IF p_purpose NOT IN ('ACCESS_DOC','TOPUP_PROOF','PAYMENT_PROOF','DISPUTE_ATTACHMENT','RESCUE_PHOTO','VENDOR_INVOICE') THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Unknown upload type.', o_err_fields = JSON_OBJECT('purpose', 'Unknown'); LEAVE proc;
  END IF;
  IF p_content_type NOT IN ('application/pdf','image/jpeg','image/png') OR LOWER(p_original_name) NOT REGEXP '\\.(pdf|jpe?g|png)$'
     OR (p_purpose = 'RESCUE_PHOTO' AND p_content_type = 'application/pdf') THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = IF(p_purpose = 'RESCUE_PHOTO', 'JPG or PNG photos only.', 'PDF, JPG or PNG only.'),
        o_err_fields = JSON_OBJECT('file', IF(p_purpose = 'RESCUE_PHOTO', 'JPG or PNG only', 'PDF, JPG or PNG only')); LEAVE proc;
  END IF;
  IF p_size_bytes <= 0 OR p_size_bytes > v_max_mb * 1048576 THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = CONCAT('Max ', CAST(v_max_mb AS UNSIGNED), ' MB.'), o_err_fields = JSON_OBJECT('file', CONCAT('Max ', CAST(v_max_mb AS UNSIGNED), ' MB')); LEAVE proc;
  END IF;
  INSERT INTO files (file_id, storage_path, original_name, content_type, size_bytes, purpose, owner_client_code, owner_vendor_id, uploaded_by)
  VALUES (p_file_id, p_storage_path, p_original_name, p_content_type, p_size_bytes, p_purpose, v_client, v_vendor, p_user_id);
END$$

-- PUT /files/:id/content — Node saved the file and checked that its content really is a PDF / JPG / PNG.
CREATE PROCEDURE sp_file_confirm_upload(IN p_user_id VARCHAR(100), IN p_file_id CHAR(36), IN p_sha256 CHAR(64), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  SET o_err_code = NULL, o_err_msg = NULL;
  UPDATE files SET upload_status = 'Uploaded', sha256 = p_sha256, scan_status = 'Clean', scanned_at = UTC_TIMESTAMP(3)
   WHERE file_id = p_file_id AND upload_status = 'Pending' AND ((p_user_id IS NULL AND uploaded_by IS NULL) OR uploaded_by = p_user_id);
  IF ROW_COUNT() = 0 THEN SET o_err_code = 'NOT_FOUND', o_err_msg = 'Upload not found.'; END IF;
END$$

-- GET /files/:id — scope check before Node issues a short-lived signed download link. Files not yet checked are refused.
CREATE PROCEDURE sp_file_get(IN p_user_id VARCHAR(100), IN p_file_id CHAR(36), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_oc VARCHAR(20); DECLARE v_ov VARCHAR(20); DECLARE v_scan VARCHAR(10); DECLARE v_found INT DEFAULT 0;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, NULL, v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  SELECT COUNT(*), MAX(owner_client_code), MAX(owner_vendor_id), MAX(scan_status) INTO v_found, v_oc, v_ov, v_scan
    FROM files WHERE file_id = p_file_id AND upload_status = 'Uploaded';
  IF v_ok = 0 OR v_found = 0 OR (v_realm = 'CLIENT_PORTAL' AND IFNULL(v_oc, '') <> v_client) OR (v_realm = 'VENDOR_PORTAL' AND IFNULL(v_ov, '') <> v_vendor) THEN
    SET o_err_code = 'NOT_FOUND', o_err_msg = 'File not found.'; LEAVE proc;
  END IF;
  IF v_scan <> 'Clean' THEN
    SET o_err_code = 'FILE_NOT_READY', o_err_msg = IF(v_scan = 'Pending', 'This file has not finished uploading.', 'This file failed the content check and cannot be opened.'); LEAVE proc;
  END IF;
  SELECT file_id AS fileId, storage_path AS storagePath, original_name AS fileName, content_type AS contentType FROM files WHERE file_id = p_file_id;
END$$

-- ── GET /portal/dashboard ────────────────────────────────────────────────────────────────────────────
-- Result sets (in order): 1 summary · 2 aging · 3 e-wallet · 4 last 5 wallet txns · 5 cash bond summary · 6 units on hire
-- 7 returned units (last 5) · 8 return branches · 9 open rescues · 10 recent EWAs · 11 contracts · 12 repair & debit-memo charges
CREATE PROCEDURE sp_portal_dashboard(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_today DATE DEFAULT fn_manila_today();
  DECLARE v_oldest DATE;
  DECLARE v_done INT DEFAULT 0; DECLARE v_bond VARCHAR(20); DECLARE v_bstatus VARCHAR(20);
  DECLARE b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short DECIMAL(15,2); DECLARE b_src JSON; DECLARE b_cno VARCHAR(30); DECLARE b_cst VARCHAR(20); DECLARE b_cexp DATE; DECLARE b_ended TINYINT;
  DECLARE s_held, s_refundable, s_unpaid, s_neg, s_open DECIMAL(15,2) DEFAULT 0; DECLARE s_pending TINYINT DEFAULT 0; DECLARE s_first TINYINT DEFAULT 1;
  DECLARE cur CURSOR FOR SELECT bond_id, status FROM cash_bonds WHERE client_code = v_client AND status IN ('Held','Withdrawal Pending');
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  SELECT MIN(due_date) INTO v_oldest FROM invoices WHERE client_code = v_client AND status <> 'Draft' AND balance > 0 AND due_date IS NOT NULL;

  -- Cash bond summary (BR-14) — computed per held bond.
  OPEN cur;
  bonds: LOOP
    FETCH cur INTO v_bond, v_bstatus;
    IF v_done = 1 THEN LEAVE bonds; END IF;
    CALL sp_bond_refund_compute(v_bond, b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short, b_src, b_cno, b_cst, b_cexp, b_ended);
    SET v_done = 0;  -- a warning raised inside the call must not end the loop
    SET s_held = s_held + b_bond, s_refundable = s_refundable + IF(v_bstatus = 'Held', b_ref, 0), s_pending = s_pending OR v_bstatus = 'Withdrawal Pending';
    IF s_first = 1 THEN SET s_unpaid = b_unpaid, s_neg = b_neg, s_open = b_pdm + b_udm, s_first = 0; END IF;
  END LOOP;
  CLOSE cur;

  -- RS1 summary
  SELECT c.client_code AS clientCode, c.client_name AS clientName, c.billing_name AS billingName, c.status AS clientStatus,
         c.allow_online AS allowOnline, c.allow_rescue AS allowRescue,
         -- the client record the portal screens read as dashboard.client (no personal data columns besides the company itself)
         JSON_OBJECT('clientCode', c.client_code, 'clientName', c.client_name, 'billingName', c.billing_name, 'status', c.status,
                     'billingCycle', c.billing_cycle, 'branchCode', c.branch_code, 'address1', c.address1, 'address2', c.address2, 'city', c.city,
                     'zipCode', c.zip_code, 'country', c.country, 'vatStatus', c.vat_status, 'creditLimit', c.credit_limit, 'aeAssigned', c.ae_user_id,
                     'allowOnline', CAST(IF(c.allow_online = 1, 'true', 'false') AS JSON), 'allowRescue', CAST(IF(c.allow_rescue = 1, 'true', 'false') AS JSON),
                     'cwsBranchAccess', IFNULL((SELECT JSON_ARRAYAGG(a.branch_code) FROM client_branch_access a WHERE a.client_code = c.client_code), JSON_ARRAY())) AS client,
         IF(ae.user_id IS NULL, NULL, JSON_OBJECT('name', ae.full_name, 'email', ae.email, 'mobile', ae.mobile)) AS accountExecutive,
         (SELECT JSON_OBJECT('role', 'Credit & Collection', 'name', u.full_name, 'phone', u.mobile, 'email', u.email)
            FROM users u JOIN user_roles r ON r.user_id = u.user_id
           WHERE r.role_code = 'CNC_OFFICER' AND u.status = 'Active' ORDER BY (u.branch_code = c.branch_code) DESC, u.user_id LIMIT 1) AS creditContact,
         JSON_OBJECT('ewa', fn_client_gate(c.client_code, 'PORTAL_EWA'),
                     'rescue', IF(JSON_UNQUOTE(JSON_EXTRACT(fn_client_gate(c.client_code, 'RESCUE_REQUEST'), '$.allowed')) = 'true',
                                  fn_rescue_wallet_gate(c.client_code), fn_client_gate(c.client_code, 'RESCUE_REQUEST'))) AS gates,
         JSON_OBJECT('creditTermBasis', IF(fn_setting_text('fin.credit_term_basis', 'invoice_date') = 'acknowledgment', 'acknowledgment', 'invoice_date'),
                     'weeklyCycleStart', fn_setting_text('fin.weekly_cycle_start', 'Friday')) AS billing,
         (SELECT COUNT(*) FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0) AS unpaidCount,
         (SELECT IFNULL(SUM(i.balance), 0) FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0) AS unpaidTotal,
         (SELECT IFNULL(SUM(i.balance), 0) FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0 AND i.due_date < v_today) AS overdue,
         (SELECT COUNT(*) FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0 AND i.due_date < v_today) AS overdueCount,
         (SELECT IFNULL(MAX(fn_days_overdue(i.due_date)), 0) FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0 AND i.due_date < v_today) AS oldestOverdueDays,
         v_oldest AS oldestDue,
         (SELECT IFNULL(SUM(i.balance), 0) FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0 AND i.due_date = v_oldest) AS oldestDueAmount,
         IFNULL((SELECT JSON_ARRAYAGG(i.invoice_no) FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0 AND i.due_date = v_oldest), JSON_ARRAY()) AS oldestDueInvoices,
         (v_oldest IS NOT NULL AND v_oldest < v_today) AS oldestDueOverdue,
         (SELECT COUNT(*) FROM notifications n WHERE n.user_id = p_user_id AND n.is_read = 0) AS unreadNotifications,
         (SELECT COUNT(*) FROM contracts k WHERE k.client_code = c.client_code AND k.status = 'Active') AS activeContracts,
         (SELECT MIN(k.expiry_date) FROM contracts k WHERE k.client_code = c.client_code AND k.status = 'Active') AS nearestExpiry,
         (SELECT IFNULL(SUM(b.amount), 0) FROM cash_bonds b WHERE b.client_code = c.client_code AND b.status IN ('Held','Withdrawal Pending')) AS cashBondHeld
    FROM clients c LEFT JOIN users ae ON ae.user_id = c.ae_user_id WHERE c.client_code = v_client;

  -- RS2 aging (same buckets as Aging and the SOA)
  SELECT IFNULL(SUM(IF(b = 'current', bal, 0)), 0) AS current, IFNULL(SUM(IF(b = 'd1_30', bal, 0)), 0) AS d1_30, IFNULL(SUM(IF(b = 'd31_60', bal, 0)), 0) AS d31_60,
         IFNULL(SUM(IF(b = 'd61_90', bal, 0)), 0) AS d61_90, IFNULL(SUM(IF(b = 'd91_180', bal, 0)), 0) AS d91_180, IFNULL(SUM(IF(b = 'd180', bal, 0)), 0) AS d180,
         IFNULL(SUM(bal), 0) AS total
    FROM (SELECT balance AS bal, fn_aging_bucket(fn_days_overdue(due_date)) AS b FROM invoices WHERE client_code = v_client AND status <> 'Draft' AND balance > 0) x;

  -- RS3 e-wallet
  SELECT balance, minimum_balance AS minimumBalance, fn_wallet_state(balance, minimum_balance) AS state,
         ROUND(minimum_balance * fn_setting_num('ewl.near_factor', 1.25), 2) AS healthyFrom
    FROM ewallets WHERE client_code = v_client;

  -- RS4 last 5 wallet transactions
  SELECT txn_id AS id, txn_at AS at, txn_type AS type, category, amount, balance_after AS balanceAfter, reference_type AS referenceType, reference_id AS referenceId, reason
    FROM ewallet_txns WHERE client_code = v_client ORDER BY txn_at DESC, txn_id DESC LIMIT 5;

  -- RS5 cash bond summary
  SELECT ROUND(s_held, 2) AS held, ROUND(s_refundable, 2) AS refundable, s_unpaid AS unpaid, s_neg AS negativeWallet, ROUND(s_open, 2) AS openDm, s_pending AS withdrawalPending;

  -- RS6 units on hire: contract, daily rate snapshot, hire days (pickup day counts), accrued (ex VAT), return / rescue state
  SELECT ch.chassis_no AS chassisNo, ch.chassis_type AS chassisType, ch.branch_code AS branchCode, ch.status, ch.current_contract_no AS contractNo,
         gp.actual_event_at AS gateOut, ch.current_gate_pass_no AS gatePassNo, cr.daily_rate AS dailyRate,
         IF(gp.actual_event_at IS NULL, NULL, DATEDIFF(v_today, fn_manila_date(gp.actual_event_at)) + 1) AS hireDays,
         IF(gp.actual_event_at IS NULL OR cr.daily_rate IS NULL, NULL, ROUND(cr.daily_rate * (DATEDIFF(v_today, fn_manila_date(gp.actual_event_at)) + 1), 2)) AS accrued,
         (SELECT JSON_OBJECT('requestNo', rr.request_no, 'preferredDate', rr.preferred_date, 'returnBranchCode', rr.return_branch_code, 'status', rr.status)
            FROM return_requests rr WHERE rr.client_code = v_client AND rr.chassis_no = ch.chassis_no AND rr.status IN ('Requested','Scheduled') LIMIT 1) AS returnRequest,
         (SELECT JSON_OBJECT('rescueNo', rs.rescue_no, 'status', rs.status, 'eta', rs.eta, 'label', 'Under rescue',
                             'crewOnTheWay', rs.status IN ('Dispatched','In Progress'))
            FROM rescues rs WHERE rs.client_code = v_client AND rs.chassis_no = ch.chassis_no AND fn_rescue_is_open(rs.status) = 1 ORDER BY rs.requested_at DESC LIMIT 1) AS rescue,
         (ch.status = 'On Hire'
           AND NOT EXISTS (SELECT 1 FROM return_requests rr WHERE rr.chassis_no = ch.chassis_no AND rr.status IN ('Requested','Scheduled'))
           AND NOT EXISTS (SELECT 1 FROM rescues rs WHERE rs.client_code = v_client AND rs.chassis_no = ch.chassis_no AND fn_rescue_is_open(rs.status) = 1)) AS canRequestReturn
    FROM chassis ch
    LEFT JOIN gate_passes gp ON gp.gate_pass_no = ch.current_gate_pass_no
    LEFT JOIN contract_rates cr ON cr.contract_no = ch.current_contract_no AND cr.equipment_type = ch.chassis_type
   WHERE ch.current_client_code = v_client AND ch.status IN ('On Hire','Rescue') ORDER BY ch.chassis_no;

  -- RS7 returned units (last 5 Gate In) with hire duration, damage and the BR-16 cross-branch code
  SELECT gi.chassis_no AS chassisNo, ch.chassis_type AS chassisType, gi.gate_pass_no AS gatePassNo, go.gate_pass_no AS outGatePassNo, gi.eir_no AS eirNo,
         gi.actual_event_at AS returnedAt, gi.branch_code AS branchCode, go.actual_event_at AS hiredAt,
         IFNULL(go.branch_code, IFNULL(gi.origin_branch_code, gi.branch_code)) AS originBranchCode,
         (IFNULL(go.branch_code, IFNULL(gi.origin_branch_code, gi.branch_code)) <> gi.branch_code) AS crossBranch, gi.cross_branch_code AS approvalCode,
         gi.general_assessment AS `condition`, gi.remarks, gi.is_force_inbound AS isForceInbound,
         IFNULL((SELECT JSON_ARRAYAGG(JSON_OBJECT('part', l.part, 'amount', l.chargeable)) FROM gate_pass_inspection_lines l WHERE l.gate_pass_no = gi.gate_pass_no AND l.chargeable > 0), JSON_ARRAY()) AS damage,
         (SELECT IFNULL(SUM(l.chargeable), 0) FROM gate_pass_inspection_lines l WHERE l.gate_pass_no = gi.gate_pass_no) AS damageCharge,
         IF(go.gate_pass_no IS NULL, NULL, DATEDIFF(fn_manila_date(gi.actual_event_at), fn_manila_date(go.actual_event_at))) AS durationDays,
         IF(go.gate_pass_no IS NULL, NULL, DATEDIFF(fn_manila_date(gi.actual_event_at), fn_manila_date(go.actual_event_at)) + 1) AS billableDays,
         cr.daily_rate AS dailyRate,
         IF(go.gate_pass_no IS NULL OR cr.daily_rate IS NULL, NULL, ROUND(cr.daily_rate * (DATEDIFF(fn_manila_date(gi.actual_event_at), fn_manila_date(go.actual_event_at)) + 1), 2)) AS leaseCharge,
         IF(go.gate_pass_no IS NULL OR cr.daily_rate IS NULL, NULL, ROUND(cr.daily_rate * (DATEDIFF(fn_manila_date(gi.actual_event_at), fn_manila_date(go.actual_event_at)) + 1)
            + (SELECT IFNULL(SUM(l.chargeable), 0) FROM gate_pass_inspection_lines l WHERE l.gate_pass_no = gi.gate_pass_no), 2)) AS finalCharges
    FROM gate_passes gi
    LEFT JOIN gate_passes go ON go.gate_pass_no = gi.paired_gate_pass_no
    LEFT JOIN chassis ch ON ch.chassis_no = gi.chassis_no
    LEFT JOIN contract_rates cr ON cr.contract_no = gi.contract_no AND cr.equipment_type = ch.chassis_type
   WHERE gi.client_code = v_client AND gi.direction = 'IN' ORDER BY gi.actual_event_at DESC LIMIT 5;

  -- RS8 return branches (home branch + CWS access)
  SELECT b.branch_code AS code, b.branch_name AS name FROM branches b
   WHERE b.branch_code IN (SELECT branch_code FROM clients WHERE client_code = v_client UNION SELECT branch_code FROM client_branch_access WHERE client_code = v_client)
   ORDER BY b.branch_name;

  -- RS9 open rescues
  SELECT rescue_no AS rescueNo, chassis_no AS chassisNo, status, requested_at AS requestedAt, is_urgent AS urgent, eta
    FROM rescues WHERE client_code = v_client AND fn_rescue_is_open(status) = 1 ORDER BY requested_at DESC;

  -- RS10 recent EWAs (6) with their lines
  SELECT e.eu_no AS euNo, e.contract_no AS contractNo, e.branch_code AS branchCode, e.trucker, e.truck_plate_no AS truckPlateNo, e.driver_name AS driverName,
         e.status, e.created_at AS createdAt, e.valid_until AS validUntil, e.cancelled_at AS cancelledAt, e.cancel_reason AS cancelReason,
         IFNULL((SELECT JSON_ARRAYAGG(JSON_OBJECT('equipmentType', l.equipment_type, 'qty', l.qty,
                   'released', (SELECT COUNT(*) FROM ewa_line_chassis c WHERE c.eu_no = l.eu_no AND c.equipment_type = l.equipment_type),
                   'usedChassis', IFNULL((SELECT JSON_ARRAYAGG(c.chassis_no) FROM ewa_line_chassis c WHERE c.eu_no = l.eu_no AND c.equipment_type = l.equipment_type), JSON_ARRAY())))
            FROM ewa_lines l WHERE l.eu_no = e.eu_no), JSON_ARRAY()) AS units
    FROM ewas e WHERE e.client_code = v_client ORDER BY e.created_at DESC, e.eu_no DESC LIMIT 6;

  -- RS11 contracts
  SELECT contract_no AS contractNo, contract_type AS contractType, contract_class AS class, status, effective_date AS effectiveDate, expiry_date AS expiryDate, unit_qty AS unitQty
    FROM contracts WHERE client_code = v_client ORDER BY (status = 'Active') DESC, effective_date DESC;

  -- RS12 repair & debit-memo charges, with how each was settled
  SELECT * FROM (
    SELECT m.memo_no AS ref, 'Debit memo' AS docType,
           CASE WHEN m.reference_type = 'Rescue' THEN 'Rescue' WHEN m.reference_type IN ('Job Order','Repair') THEN 'Repair'
                WHEN m.reference_type = 'Park & Fix' THEN 'Park & Fix' ELSE IFNULL(m.category, m.reference_type) END AS kind,
           m.reason, m.amount, m.created_at AS at, m.status,
           IF(COALESCE(m.rescue_no, m.jo_no, m.reference_id) IS NULL, m.reference_type, CONCAT(m.reference_type, ' ', COALESCE(m.rescue_no, m.jo_no, m.reference_id))) AS source,
           m.reference_invoice_no AS invoiceNo,
           COALESCE(
             (SELECT JSON_OBJECT('how', 'ewallet', 'txnId', t.txn_id, 'at', t.txn_at, 'balanceAfter', t.balance_after) FROM ewallet_txns t
               WHERE t.client_code = v_client AND t.txn_type = 'Deduction' AND t.reversed_by_txn_id IS NULL
                 AND (t.reference_id = m.memo_no OR t.reference_id = COALESCE(m.rescue_no, m.jo_no, m.reference_id)) ORDER BY t.txn_at LIMIT 1),
             IF(m.status = 'Pending Approval', JSON_OBJECT('how', 'pending'), NULL),
             IF(m.status = 'Applied' AND m.applied_to IS NOT NULL, JSON_OBJECT('how', 'invoice', 'invoiceNo', m.applied_to), NULL),
             JSON_OBJECT('how', 'open')) AS settlement
      FROM memos m WHERE m.client_code = v_client AND m.memo_type = 'Debit' AND m.status NOT IN ('Draft','Rejected')
    UNION ALL
    SELECT i.invoice_no, 'Repair invoice', 'Repair',
           (SELECT GROUP_CONCAT(l.description ORDER BY l.line_no SEPARATOR '; ') FROM invoice_lines l WHERE l.invoice_no = i.invoice_no),
           i.total, i.issued_at, fn_payment_status(i.status, i.balance, i.amount_paid, i.credited, i.due_date),
           IFNULL((SELECT CONCAT('Chassis ', l.chassis_no) FROM invoice_lines l WHERE l.invoice_no = i.invoice_no AND l.chassis_no IS NOT NULL LIMIT 1), 'Gate In inspection'),
           i.invoice_no,
           IF(i.balance > 0, JSON_OBJECT('how', 'invoice_due', 'invoiceNo', i.invoice_no, 'balance', i.balance, 'dueDate', i.due_date), JSON_OBJECT('how', 'paid', 'invoiceNo', i.invoice_no))
      FROM invoices i WHERE i.client_code = v_client AND i.bill_type = 'Repair' AND i.status NOT IN ('Draft','Cancelled')
  ) ch ORDER BY at DESC;
END$$

-- ── Notifications ────────────────────────────────────────────────────────────────────────────────────
CREATE PROCEDURE sp_portal_notifications_list(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT notification_id AS id, created_at AS at, title, body, link, is_read AS `read`, requires_ack AS requiresAck
    FROM notifications WHERE user_id = p_user_id ORDER BY created_at DESC LIMIT 50;
END$$

-- p_notification_id NULL = mark all as read.
CREATE PROCEDURE sp_portal_notifications_mark_read(IN p_user_id VARCHAR(100), IN p_notification_id BIGINT UNSIGNED, OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  UPDATE notifications SET is_read = 1 WHERE user_id = p_user_id AND is_read = 0 AND (p_notification_id IS NULL OR notification_id = p_notification_id);
END$$

-- ── Feedback / rating (sent to the Account Executive) ────────────────────────────────────────────────
CREATE PROCEDURE sp_portal_feedback_submit(IN p_user_id VARCHAR(100), IN p_category VARCHAR(60), IN p_subject VARCHAR(200), IN p_message VARCHAR(4000),
  IN p_reference VARCHAR(60), IN p_rating TINYINT, IN p_topic VARCHAR(60), IN p_source VARCHAR(200),
  OUT o_feedback_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_subject VARCHAR(200); DECLARE v_message VARCHAR(4000); DECLARE v_ae VARCHAR(100); DECLARE v_cname VARCHAR(200);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF p_rating IS NOT NULL AND (p_rating < 1 OR p_rating > 5) THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Choose a rating from 1 to 5 stars.', o_err_fields = JSON_OBJECT('rating', 'Choose 1 to 5 stars'); LEAVE proc;
  END IF;
  -- A star rating needs no subject or message.
  SET v_subject = COALESCE(NULLIF(TRIM(p_subject), ''), IF(p_rating IS NULL, NULL, CONCAT(p_rating, '-star rating', IF(IFNULL(TRIM(p_topic), '') = '', '', CONCAT(' — ', TRIM(p_topic))))));
  SET v_message = COALESCE(NULLIF(TRIM(p_message), ''), IF(p_rating IS NULL, NULL, '(no comment)'));
  IF IFNULL(TRIM(p_category), '') = '' OR v_subject IS NULL OR v_message IS NULL THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Category, subject and message are required.',
        o_err_fields = JSON_OBJECT('category', IF(IFNULL(TRIM(p_category), '') = '', 'Required', ''), 'subject', IF(v_subject IS NULL, 'Required', ''), 'message', IF(v_message IS NULL, 'Required', '')); LEAVE proc;
  END IF;
  SELECT ae_user_id, client_name INTO v_ae, v_cname FROM clients WHERE client_code = v_client;
  START TRANSACTION;
  CALL sp_next_number('FB', 'FB-', 5, o_feedback_id);
  INSERT INTO client_feedback (feedback_id, client_code, category, topic, rating, subject, message, reference, submitted_by)
  VALUES (o_feedback_id, v_client, TRIM(p_category), NULLIF(TRIM(p_topic), ''), p_rating, v_subject, v_message, NULLIF(TRIM(p_reference), ''), p_user_id);
  CALL sp_notify_user(v_ae, 'client.feedback', CONCAT(IF(p_rating IS NULL, TRIM(p_category), CONCAT(REPEAT('★', p_rating), ' rating')), ' — ', v_cname),
       CONCAT(v_subject, IF(IFNULL(TRIM(p_reference), '') = '', '', CONCAT(' (', TRIM(p_reference), ')'))), '/clients');
  CALL sp_audit_write(p_user_id, 'CLIENT', 'client.feedback', 'client', v_client, NULL, NULL,
       JSON_OBJECT('id', o_feedback_id, 'category', p_category, 'rating', p_rating, 'subject', v_subject), NULL, p_source);
  COMMIT;
  SELECT feedback_id AS id, client_code AS clientCode, category, topic, rating, subject, message, reference, status, submitted_at AS submittedAt
    FROM client_feedback WHERE feedback_id = o_feedback_id;
END$$

CREATE PROCEDURE sp_portal_feedback_list(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT feedback_id AS id, category, topic, rating, subject, message, reference, status, submitted_at AS submittedAt, submitted_by AS submittedBy
    FROM client_feedback WHERE client_code = v_client ORDER BY submitted_at DESC LIMIT 50;
END$$

-- ── POST /portal/returns — ask Delbros to collect an on-hire unit (proposed, Q-PTL-03; BR-16 cross-branch) ──
CREATE PROCEDURE sp_portal_return_request(IN p_user_id VARCHAR(100), IN p_chassis_no VARCHAR(30), IN p_return_branch VARCHAR(10), IN p_preferred_date DATE,
  IN p_notes VARCHAR(1000), IN p_source VARCHAR(200),
  OUT o_request_no VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_branch VARCHAR(10); DECLARE v_contract VARCHAR(30); DECLARE v_gp VARCHAR(20); DECLARE v_origin VARCHAR(10);
  DECLARE v_rsc VARCHAR(20); DECLARE v_rsc_status VARCHAR(20); DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100); DECLARE v_today DATE DEFAULT fn_manila_today();
  DECLARE v_body TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  START TRANSACTION;
  SELECT status, branch_code, current_contract_no, current_gate_pass_no INTO v_status, v_branch, v_contract, v_gp
    FROM chassis WHERE chassis_no = p_chassis_no AND current_client_code = v_client FOR UPDATE;
  IF v_status IS NULL THEN ROLLBACK; SET o_err_code = 'NOT_FOUND', o_err_msg = 'That unit is not on hire to your account.'; LEAVE proc; END IF;
  IF v_status <> 'On Hire' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_chassis_no, ' is under ', LOWER(v_status), ' — the return is arranged once it is back on hire.'); LEAVE proc; END IF;
  SELECT rescue_no, status INTO v_rsc, v_rsc_status FROM rescues WHERE client_code = v_client AND chassis_no = p_chassis_no AND fn_rescue_is_open(status) = 1 LIMIT 1;
  IF v_rsc IS NOT NULL THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_chassis_no, ' is under rescue (', v_rsc, ', ', LOWER(v_rsc_status), ') — request the return after the rescue is completed or cancelled.'); LEAVE proc; END IF;
  IF EXISTS (SELECT 1 FROM return_requests WHERE chassis_no = p_chassis_no AND status IN ('Requested','Scheduled')) THEN
    ROLLBACK; SET o_err_code = 'DUPLICATE', o_err_msg = CONCAT('A return is already requested for ', p_chassis_no, '.'); LEAVE proc;
  END IF;
  SET o_err_fields = JSON_OBJECT();
  IF p_return_branch NOT IN (SELECT branch_code FROM clients WHERE client_code = v_client UNION SELECT branch_code FROM client_branch_access WHERE client_code = v_client UNION SELECT v_branch) THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.returnBranchCode', 'Choose one of your branches');
  END IF;
  IF p_preferred_date IS NULL THEN SET o_err_fields = JSON_SET(o_err_fields, '$.preferredDate', 'Required');
  ELSEIF p_preferred_date < v_today THEN SET o_err_fields = JSON_SET(o_err_fields, '$.preferredDate', 'Cannot be in the past');
  ELSEIF p_preferred_date > v_today + INTERVAL 60 DAY THEN SET o_err_fields = JSON_SET(o_err_fields, '$.preferredDate', 'Within the next 60 days');
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;

  SELECT IFNULL((SELECT branch_code FROM gate_passes WHERE gate_pass_no = v_gp), v_branch) INTO v_origin;
  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  CALL sp_next_number('RTN', 'RTN-', 6, o_request_no);
  INSERT INTO return_requests (request_no, client_code, chassis_no, contract_no, origin_branch_code, return_branch_code, preferred_date, notes, status, requested_by)
  VALUES (o_request_no, v_client, p_chassis_no, v_contract, v_origin, p_return_branch, p_preferred_date, NULLIF(TRIM(p_notes), ''), 'Requested', p_user_id);

  SET v_body = CONCAT(v_cname, ' · ', o_request_no, ' · return at ', p_return_branch, ' on ', DATE_FORMAT(p_preferred_date, '%Y-%m-%d'),
                      IF(v_origin <> p_return_branch, CONCAT(' — cross-branch from ', v_origin, ', IT approval code needed (BR-16)'), ''));
  -- Who is told: the return branch's Branch Generalists, the Account Executive; the client gets a confirmation.
  CALL sp_outbox_queue_roles('return_request', o_request_no, 'client.return_request', JSON_ARRAY('BRANCH_GENERALIST'), p_return_branch,
       CONCAT('Branch Generalist, ', p_return_branch, ' (schedules the Gate In)'), CONCAT('Return requested: ', p_chassis_no), v_body, NULL);
  CALL sp_outbox_queue('return_request', o_request_no, 'client.return_request', 'Email', 'Delbros', 'Account Executive', (SELECT email FROM users WHERE user_id = v_ae),
       CONCAT('Return requested: ', p_chassis_no), v_body, NULL, 0, (SELECT full_name FROM users WHERE user_id = v_ae));
  CALL sp_outbox_queue('return_request', o_request_no, 'client.return_request', 'Email', 'Client', 'Confirmation to you', v_email,
       CONCAT('Return request ', o_request_no, ' received'), v_body, NULL, 0, v_name);
  CALL sp_notify_roles(JSON_ARRAY('BRANCH_GENERALIST'), p_return_branch, 'client.return_request', CONCAT('Return requested: ', p_chassis_no), v_body, '/gate');
  CALL sp_notify_user(v_ae, 'client.return_request', CONCAT('Return requested: ', p_chassis_no), v_body, '/clients');
  CALL sp_audit_write(p_user_id, 'CLIENT', 'portal.return_requested', 'chassis', p_chassis_no, p_return_branch, NULL,
       JSON_OBJECT('requestNo', o_request_no, 'returnBranchCode', p_return_branch, 'preferredDate', p_preferred_date, 'crossBranch', v_origin <> p_return_branch), NULL, p_source);
  COMMIT;

  SELECT r.request_no AS requestNo, r.chassis_no AS chassisNo, r.contract_no AS contractNo, r.origin_branch_code AS originBranchCode, r.return_branch_code AS returnBranchCode,
         r.preferred_date AS preferredDate, r.notes, r.status, r.requested_at AS requestedAt, (r.origin_branch_code <> r.return_branch_code) AS crossBranch
    FROM return_requests r WHERE r.request_no = o_request_no;
  SELECT queued_at AS at, channel, audience, recipient_label AS recipient, recipient_name AS recipientName, to_address AS `to`, status FROM message_outbox
   WHERE entity_type = 'return_request' AND entity_id = o_request_no ORDER BY message_id;
END$$

DELIMITER ;

-- Removed (no S3 / GuardDuty): files are checked by the API when uploaded.
DROP PROCEDURE IF EXISTS sp_file_pending_scan;
DROP PROCEDURE IF EXISTS sp_file_scan_result;
