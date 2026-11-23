-- =====================================================================================================
-- 07_sp_billing.sql : Invoices & SOA — list, details, acknowledge receipt (credit term start, DBL-CNC-005),
--                     proof of payment, dispute, statement of account, email SOA, hire-days coverage
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_invoice_list;
DROP PROCEDURE IF EXISTS sp_portal_invoices_all;
DROP PROCEDURE IF EXISTS sp_invoice_get;
DROP PROCEDURE IF EXISTS sp_invoice_acknowledge;
DROP PROCEDURE IF EXISTS sp_payment_advice_create;
DROP PROCEDURE IF EXISTS sp_invoice_dispute_create;
DROP PROCEDURE IF EXISTS sp_soa_get;
DROP PROCEDURE IF EXISTS sp_soa_email;
DROP PROCEDURE IF EXISTS sp_hire_coverage;

DELIMITER $$

-- GET /portal/invoices — RS1 rows · RS2 {total, unpaidTotal}
-- p_payment_status: Unpaid | Partially Paid | Paid | Overdue | Credited | Cancelled | NULL
CREATE PROCEDURE sp_invoice_list(IN p_user_id VARCHAR(100), IN p_q VARCHAR(100), IN p_payment_status VARCHAR(20), IN p_bill_type VARCHAR(30),
  IN p_from DATE, IN p_to DATE, IN p_page INT, IN p_page_size INT, OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_size INT DEFAULT LEAST(GREATEST(IFNULL(p_page_size, 8), 1), 100);
  DECLARE v_offset INT DEFAULT (GREATEST(IFNULL(p_page, 1), 1) - 1) * LEAST(GREATEST(IFNULL(p_page_size, 8), 1), 100);
  DECLARE v_q VARCHAR(102) DEFAULT CONCAT('%', IFNULL(TRIM(p_q), ''), '%');
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_inv;
  CREATE TEMPORARY TABLE tmp_inv AS
  SELECT i.invoice_no AS invoiceNo, i.invoice_date AS invoiceDate, i.bill_type AS billType, i.contract_no AS contractNo, i.branch_code AS branchCode,
         i.period_start AS periodStart, i.period_end AS periodEnd, i.subtotal AS net, i.vat, i.total, i.amount_paid AS amountPaid, i.credited, i.balance,
         i.due_basis AS dueBasis, i.due_date AS dueDate, i.acknowledged_at AS acknowledgedAt, i.status,
         fn_payment_status(i.status, i.balance, i.amount_paid, i.credited, i.due_date) AS paymentStatus,
         IF(i.balance > 0, fn_days_overdue(i.due_date), 0) AS daysOverdue,
         IF(i.balance > 0 AND i.due_date >= fn_manila_today(), DATEDIFF(i.due_date, fn_manila_today()), NULL) AS dueInDays,
         (i.due_basis = 'Acknowledgment' AND i.acknowledged_at IS NULL AND i.status <> 'Cancelled') AS awaitingAcknowledgment,
         (SELECT GROUP_CONCAT(DISTINCT l.chassis_no ORDER BY l.chassis_no) FROM invoice_lines l WHERE l.invoice_no = i.invoice_no AND l.chassis_no IS NOT NULL) AS units,
         EXISTS (SELECT 1 FROM payment_advices a WHERE a.invoice_no = i.invoice_no AND a.status = 'Submitted') AS proofSent,
         EXISTS (SELECT 1 FROM invoice_disputes d WHERE d.invoice_no = i.invoice_no AND d.status IN ('Submitted','Under review')) AS disputed
    FROM invoices i
   WHERE i.client_code = v_client AND i.status <> 'Draft'
     AND (p_bill_type IS NULL OR p_bill_type = '' OR i.bill_type = p_bill_type)
     AND (p_from IS NULL OR i.invoice_date >= p_from) AND (p_to IS NULL OR i.invoice_date <= p_to)
     AND (p_q IS NULL OR p_q = '' OR i.invoice_no LIKE v_q OR i.contract_no LIKE v_q
          OR EXISTS (SELECT 1 FROM invoice_lines l WHERE l.invoice_no = i.invoice_no AND l.chassis_no LIKE v_q));

  SELECT * FROM tmp_inv WHERE (p_payment_status IS NULL OR p_payment_status = '' OR paymentStatus = p_payment_status)
   ORDER BY invoiceDate DESC, invoiceNo DESC LIMIT v_offset, v_size;
  SELECT COUNT(*) AS total, IFNULL(SUM(balance), 0) AS balanceTotal FROM tmp_inv WHERE (p_payment_status IS NULL OR p_payment_status = '' OR paymentStatus = p_payment_status);
  DROP TEMPORARY TABLE tmp_inv;
END$$

-- GET /portal/invoices?view=all — the portal Invoices & SOA page loads every invoice once and filters in the browser.
-- RS1 invoices · RS2 lines · RS3 receipts applied (Official / Provisional) · RS4 credit memos applied · RS5 proof of payment · RS6 disputes
CREATE PROCEDURE sp_portal_invoices_all(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_hold INT DEFAULT fn_setting_num('cnc.hold_threshold_days', 30);
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  SELECT i.invoice_no AS invoiceNo, i.client_code AS clientCode, c.client_name AS clientName, i.contract_no AS contractNo, i.branch_code AS branchCode,
         IFNULL(b.branch_name, i.branch_code) AS branchName, i.bill_type AS billType, i.billing_cycle AS billingCycle, i.batch_no AS batchNo,
         i.invoice_date AS invoiceDate, i.period_start AS periodStart, i.period_end AS periodEnd, i.subtotal, i.vat, i.total, i.amount_paid AS amountPaid,
         i.credited, i.balance, i.credit_term_days AS creditTermDays, i.due_basis AS dueBasis, i.due_date AS dueDate, i.acknowledged_at AS acknowledgedAt,
         i.acknowledged_by AS acknowledgedBy, i.acknowledged_via AS acknowledgedVia, i.status, i.issued_at AS issuedAt, i.held_reason AS heldReason,
         i.cancel_reason AS cancelReason, i.sent_at AS sentAt,
         fn_payment_status(i.status, i.balance, i.amount_paid, i.credited, i.due_date) AS payment,
         IF(i.balance > 0, fn_days_overdue(i.due_date), 0) AS daysOverdue,
         IF(fn_payment_status(i.status, i.balance, i.amount_paid, i.credited, i.due_date) = 'Overdue', v_hold - fn_days_overdue(i.due_date), NULL) AS daysToHold,
         EXISTS (SELECT 1 FROM invoice_lines l WHERE l.invoice_no = i.invoice_no AND l.is_held = 1) AS hasHeld,
         EXISTS (SELECT 1 FROM invoice_lines l WHERE l.invoice_no = i.invoice_no AND l.line_type = 'Lease') AS isLease,
         (SELECT IFNULL(SUM(a.amount), 0) FROM receipt_applications a JOIN receipts r ON r.receipt_no = a.receipt_no
           WHERE a.invoice_no = i.invoice_no AND r.status = 'Provisional') AS pendingClearance
    FROM invoices i JOIN clients c ON c.client_code = i.client_code LEFT JOIN branches b ON b.branch_code = i.branch_code
   WHERE i.client_code = v_client AND i.status <> 'Draft'
   ORDER BY i.invoice_date DESC, i.invoice_no DESC;

  SELECT l.invoice_no AS invoiceNo, l.line_no AS lineNo, l.line_type AS lineType, l.description, l.chassis_no AS chassisNo, l.equipment_type AS equipmentType,
         l.rate_type AS rateType, l.date_from AS dateFrom, l.date_to AS dateTo, l.days, l.rate, l.amount, l.is_held AS held
    FROM invoice_lines l JOIN invoices i ON i.invoice_no = l.invoice_no
   WHERE i.client_code = v_client AND i.status <> 'Draft' ORDER BY l.invoice_no, l.line_no;

  -- A PR that became an OR is shown once, as the OR (with the PR it came from).
  SELECT a.invoice_no AS invoiceNo, r.receipt_no AS receiptNo, r.pr_no AS fromPr, IF(r.receipt_type = 'OR', 'Official receipt', 'Provisional receipt') AS series,
         r.status, r.receipt_date AS date, a.amount, r.method, r.check_bank AS bank, r.check_no AS checkNo, r.reference,
         (r.status NOT IN ('Provisional','Bounced','Cancelled')) AS counted
    FROM receipt_applications a JOIN receipts r ON r.receipt_no = a.receipt_no JOIN invoices i ON i.invoice_no = a.invoice_no
   WHERE i.client_code = v_client AND i.status <> 'Draft' AND r.status <> 'Cancelled' AND (r.receipt_type = 'OR' OR r.or_no IS NULL)
   ORDER BY r.receipt_date, r.receipt_no;

  SELECT IFNULL(m.applied_to, m.reference_invoice_no) AS invoiceNo, m.memo_no AS memoNo, m.amount, m.reason, m.category, m.applied_at AS appliedAt
    FROM memos m
   WHERE m.client_code = v_client AND m.memo_type = 'Credit' AND m.status = 'Applied' AND IFNULL(m.applied_to, m.reference_invoice_no) IS NOT NULL
   ORDER BY m.applied_at;

  SELECT a.invoice_no AS invoiceNo, a.advice_id AS id, a.amount, a.paid_on AS paidOn, a.method, a.bank, a.reference, a.proof_file_id AS proofFileId,
         f.original_name AS proofFileName, a.remarks, a.status, a.receipt_no AS receiptNo, a.reject_reason AS rejectReason, a.submitted_at AS submittedAt
    FROM payment_advices a LEFT JOIN files f ON f.file_id = a.proof_file_id
   WHERE a.client_code = v_client ORDER BY a.submitted_at DESC;

  SELECT d.invoice_no AS invoiceNo, d.dispute_id AS id, d.reason, d.details, d.amount_disputed AS amountDisputed, d.attachment_file_id AS attachmentFileId,
         f.original_name AS attachment, d.status, d.resolution, d.submitted_at AS submittedAt
    FROM invoice_disputes d LEFT JOIN files f ON f.file_id = d.attachment_file_id
   WHERE d.client_code = v_client ORDER BY d.submitted_at DESC;
END$$

-- GET /portal/invoices/:no — RS1 header · RS2 lines · RS3 receipts that paid it · RS4 credit / debit memos · RS5 proof of payment · RS6 disputes · RS7 history
CREATE PROCEDURE sp_invoice_get(IN p_user_id VARCHAR(100), IN p_invoice_no VARCHAR(30), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF NOT EXISTS (SELECT 1 FROM invoices WHERE invoice_no = p_invoice_no AND client_code = v_client AND status <> 'Draft') THEN
    SET o_err_code = 'NOT_FOUND', o_err_msg = 'Invoice not found.'; LEAVE proc;
  END IF;
  SELECT i.invoice_no AS invoiceNo, i.invoice_date AS invoiceDate, i.bill_type AS billType, i.billing_cycle AS billingCycle, i.contract_no AS contractNo,
         i.branch_code AS branchCode, i.period_start AS periodStart, i.period_end AS periodEnd, i.subtotal AS net, i.vat, i.total, i.amount_paid AS amountPaid,
         i.credited, i.balance, i.credit_term_days AS creditTermDays, i.due_basis AS dueBasis, i.due_date AS dueDate,
         i.acknowledged_at AS acknowledgedAt, au.full_name AS acknowledgedByName, i.acknowledged_via AS acknowledgedVia, i.status, i.issued_at AS issuedAt,
         i.sent_to AS sentTo, i.sent_at AS sentAt, i.cancel_reason AS cancelReason,
         fn_payment_status(i.status, i.balance, i.amount_paid, i.credited, i.due_date) AS paymentStatus, IF(i.balance > 0, fn_days_overdue(i.due_date), 0) AS daysOverdue,
         (i.due_basis = 'Acknowledgment' AND i.acknowledged_at IS NULL AND i.status <> 'Cancelled') AS canAcknowledge,
         (i.status <> 'Cancelled' AND i.balance > 0) AS canSendProof,
         (i.status <> 'Cancelled' AND NOT EXISTS (SELECT 1 FROM invoice_disputes d WHERE d.invoice_no = i.invoice_no AND d.status IN ('Submitted','Under review'))) AS canDispute,
         JSON_OBJECT('clientCode', c.client_code, 'billingName', c.billing_name, 'address1', c.address1, 'address2', c.address2, 'city', c.city, 'tin', c.tin, 'vatStatus', c.vat_status) AS billTo,
         JSON_OBJECT('name', fn_setting_text('co.name', 'Delbros Leasing Inc.'), 'address', fn_setting_text('co.address', ''), 'tin', fn_setting_text('co.tin', ''),
                     'birPermit', fn_setting_text('co.bir_permit', ''), 'entity', b.billing_entity) AS issuer
    FROM invoices i JOIN clients c ON c.client_code = i.client_code JOIN branches b ON b.branch_code = i.branch_code LEFT JOIN users au ON au.user_id = i.acknowledged_by
   WHERE i.invoice_no = p_invoice_no;
  SELECT line_no AS lineNo, line_type AS lineType, description, chassis_no AS chassisNo, equipment_type AS equipmentType, rate_type AS rateType,
         date_from AS dateFrom, date_to AS dateTo, days, rate, amount FROM invoice_lines WHERE invoice_no = p_invoice_no ORDER BY line_no;
  SELECT r.receipt_no AS receiptNo, IF(r.receipt_type = 'OR', 'Official', 'Provisional') AS receiptKind, r.receipt_date AS receiptDate, r.method, r.reference,
         a.amount AS applied, r.status, r.pr_no AS fromPrNo, r.or_no AS becameOrNo
    FROM receipt_applications a JOIN receipts r ON r.receipt_no = a.receipt_no WHERE a.invoice_no = p_invoice_no AND r.status <> 'Cancelled' ORDER BY r.receipt_date;
  SELECT memo_no AS memoNo, memo_type AS memoType, category, amount, reason, status, applied_at AS appliedAt
    FROM memos WHERE (applied_to = p_invoice_no OR reference_invoice_no = p_invoice_no) AND client_code = v_client AND status NOT IN ('Draft','Rejected') ORDER BY created_at;
  SELECT advice_id AS id, amount, paid_on AS paidOn, method, bank, reference, proof_file_id AS proofFileId, remarks, status, receipt_no AS receiptNo, reject_reason AS rejectReason, submitted_at AS submittedAt
    FROM payment_advices WHERE invoice_no = p_invoice_no AND client_code = v_client ORDER BY submitted_at DESC;
  SELECT dispute_id AS id, reason, details, amount_disputed AS amountDisputed, attachment_file_id AS attachmentFileId, status, resolution, submitted_at AS submittedAt
    FROM invoice_disputes WHERE invoice_no = p_invoice_no AND client_code = v_client ORDER BY submitted_at DESC;
  SELECT e.event_at AS at, IFNULL(u.full_name, e.event_by) AS byName, e.action, e.note FROM invoice_events e LEFT JOIN users u ON u.user_id = e.event_by
   WHERE e.invoice_no = p_invoice_no ORDER BY e.event_id;
END$$

-- POST /portal/invoices/:no/acknowledge — the credit term starts today (provisional, fin.credit_term_basis = acknowledgment).
CREATE PROCEDURE sp_invoice_acknowledge(IN p_user_id VARCHAR(100), IN p_invoice_no VARCHAR(30), IN p_source VARCHAR(200),
  OUT o_due_date DATE, OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_basis VARCHAR(20); DECLARE v_ack DATETIME(3); DECLARE v_due DATE; DECLARE v_term INT; DECLARE v_inv_date DATE;
  DECLARE v_today DATE DEFAULT fn_manila_today(); DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  START TRANSACTION;
  SELECT status, due_basis, acknowledged_at, due_date, credit_term_days, invoice_date INTO v_status, v_basis, v_ack, v_due, v_term, v_inv_date
    FROM invoices WHERE invoice_no = p_invoice_no AND client_code = v_client AND status <> 'Draft' FOR UPDATE;
  IF v_status IS NULL THEN ROLLBACK; SET o_err_code = 'NOT_FOUND', o_err_msg = 'Invoice not found.'; LEAVE proc; END IF;
  IF v_status = 'Cancelled' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_invoice_no, ' is cancelled.'); LEAVE proc; END IF;
  IF v_basis <> 'Acknowledgment' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_invoice_no, ' is a legacy invoice — its due date ', IFNULL(v_due, '—'), ' was set when it was issued.'); LEAVE proc; END IF;
  IF v_ack IS NOT NULL THEN ROLLBACK; SET o_err_code = 'ALREADY_DECIDED', o_err_msg = CONCAT(p_invoice_no, ' was already acknowledged on ', DATE_FORMAT(v_ack + INTERVAL 8 HOUR, '%d-%b-%Y %H:%i'), '.'); LEAVE proc; END IF;
  IF v_today < v_inv_date THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'The acknowledgment cannot be before the invoice date.'; LEAVE proc; END IF;
  SET o_due_date = v_today + INTERVAL v_term DAY;
  UPDATE invoices SET acknowledged_at = UTC_TIMESTAMP(3), acknowledged_by = p_user_id, acknowledged_via = 'Client portal', due_date = o_due_date, row_version = row_version + 1
   WHERE invoice_no = p_invoice_no;
  INSERT INTO invoice_events (invoice_no, event_by, action, note)
  VALUES (p_invoice_no, p_user_id, 'Acknowledged', CONCAT('Client portal · due ', o_due_date, ' (', v_term, ' days from acknowledgment, DBL-CNC-005)'));
  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  CALL sp_notify_user(v_ae, 'billing.acknowledged', CONCAT('Invoice ', p_invoice_no, ' acknowledged'), CONCAT(v_cname, ' · due ', o_due_date), '/billing/invoices');
  CALL sp_notify_roles(JSON_ARRAY('ACCOUNTING'), NULL, 'billing.acknowledged', CONCAT('Invoice ', p_invoice_no, ' acknowledged'), CONCAT(v_cname, ' · due ', o_due_date), '/billing/invoices');
  CALL sp_audit_write(p_user_id, 'CLIENT', 'invoice.acknowledged', 'invoice', p_invoice_no, NULL, NULL,
       JSON_OBJECT('via', 'Client portal', 'dueDate', o_due_date, 'basis', 'Acknowledgment'), NULL, p_source);
  COMMIT;
END$$

-- POST /portal/invoices/:no/payment-advice — proof of payment (proposed scope). Does not change the balance.
CREATE PROCEDURE sp_payment_advice_create(IN p_user_id VARCHAR(100), IN p_invoice_no VARCHAR(30), IN p_amount DECIMAL(15,2), IN p_paid_on DATE,
  IN p_method VARCHAR(50), IN p_bank VARCHAR(100), IN p_reference VARCHAR(80), IN p_proof_file_id CHAR(36), IN p_remarks VARCHAR(500), IN p_source VARCHAR(200),
  OUT o_advice_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_balance DECIMAL(15,2); DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100); DECLARE v_body TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT status, balance INTO v_status, v_balance FROM invoices WHERE invoice_no = p_invoice_no AND client_code = v_client AND status <> 'Draft';
  IF v_status IS NULL THEN SET o_err_code = 'NOT_FOUND', o_err_msg = 'Invoice not found.'; LEAVE proc; END IF;
  IF v_status = 'Cancelled' OR v_balance <= 0 THEN SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_invoice_no, ' has nothing left to pay.'); LEAVE proc; END IF;
  SET o_err_fields = JSON_OBJECT();
  IF p_amount IS NULL OR p_amount <= 0 THEN SET o_err_fields = JSON_SET(o_err_fields, '$.amount', 'Enter the amount paid');
  ELSEIF p_amount > v_balance THEN SET o_err_fields = JSON_SET(o_err_fields, '$.amount', CONCAT('More than the balance (₱', FORMAT(v_balance, 2), ')')); END IF;
  IF p_paid_on IS NULL THEN SET o_err_fields = JSON_SET(o_err_fields, '$.paidOn', 'Required');
  ELSEIF p_paid_on > fn_manila_today() THEN SET o_err_fields = JSON_SET(o_err_fields, '$.paidOn', 'Cannot be in the future'); END IF;
  IF IFNULL(TRIM(p_method), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.method', 'Required'); END IF;
  IF IFNULL(TRIM(p_reference), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.reference', 'Required'); END IF;
  IF NOT EXISTS (SELECT 1 FROM files WHERE file_id = p_proof_file_id AND uploaded_by = p_user_id AND purpose = 'PAYMENT_PROOF' AND upload_status = 'Uploaded' AND entity_id IS NULL) THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.proofFile', 'Attach the proof');
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;
  IF EXISTS (SELECT 1 FROM payment_advices WHERE client_code = v_client AND reference_norm = UPPER(TRIM(p_reference)) AND status <> 'Rejected') THEN
    SET o_err_code = 'DUPLICATE', o_err_msg = CONCAT('Reference ', TRIM(p_reference), ' was already sent — Accounting is checking it.'), o_err_fields = JSON_OBJECT('reference', 'Already sent'); LEAVE proc;
  END IF;

  START TRANSACTION;
  CALL sp_next_number('PA', 'PA-', 6, o_advice_id);
  INSERT INTO payment_advices (advice_id, client_code, invoice_no, amount, paid_on, method, bank, reference, proof_file_id, remarks, submitted_by)
  VALUES (o_advice_id, v_client, p_invoice_no, p_amount, p_paid_on, TRIM(p_method), NULLIF(TRIM(p_bank), ''), TRIM(p_reference), p_proof_file_id, NULLIF(TRIM(p_remarks), ''), p_user_id);
  UPDATE files SET entity_type = 'payment_advice', entity_id = o_advice_id WHERE file_id = p_proof_file_id;
  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  SET v_body = CONCAT(p_invoice_no, ' · ₱', FORMAT(p_amount, 2), ' · ', TRIM(p_method), ' · ref ', TRIM(p_reference));
  CALL sp_notify_roles(JSON_ARRAY('ACCOUNTING','TREASURY'), NULL, 'billing.payment_advice', CONCAT('Proof of payment ', o_advice_id, ': ', v_cname), v_body, '/billing/receipts');
  CALL sp_notify_user(v_ae, 'billing.payment_advice', CONCAT('Proof of payment ', o_advice_id, ': ', v_cname), v_body, '/billing/receipts');
  INSERT INTO invoice_events (invoice_no, event_by, action, note) VALUES (p_invoice_no, p_user_id, 'Proof of payment sent', CONCAT(o_advice_id, ' · ', v_body));
  CALL sp_audit_write(p_user_id, 'CLIENT', 'portal.payment_advice', 'invoice', p_invoice_no, NULL, NULL,
       JSON_OBJECT('id', o_advice_id, 'amount', p_amount, 'paidOn', p_paid_on, 'method', p_method, 'reference', p_reference), NULL, p_source);
  COMMIT;
END$$

-- POST /portal/invoices/:no/dispute — one open dispute per invoice; a correction comes as a credit memo.
CREATE PROCEDURE sp_invoice_dispute_create(IN p_user_id VARCHAR(100), IN p_invoice_no VARCHAR(30), IN p_reason VARCHAR(200), IN p_details VARCHAR(2000),
  IN p_amount_disputed DECIMAL(15,2), IN p_attachment_file_id CHAR(36), IN p_source VARCHAR(200),
  OUT o_dispute_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_total DECIMAL(15,2); DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100); DECLARE v_body TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT status, total INTO v_status, v_total FROM invoices WHERE invoice_no = p_invoice_no AND client_code = v_client AND status <> 'Draft';
  IF v_status IS NULL THEN SET o_err_code = 'NOT_FOUND', o_err_msg = 'Invoice not found.'; LEAVE proc; END IF;
  IF v_status = 'Cancelled' THEN SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_invoice_no, ' is cancelled.'); LEAVE proc; END IF;
  IF EXISTS (SELECT 1 FROM invoice_disputes WHERE invoice_no = p_invoice_no AND status IN ('Submitted','Under review')) THEN
    SET o_err_code = 'DUPLICATE', o_err_msg = CONCAT(p_invoice_no, ' already has an open dispute.'); LEAVE proc;
  END IF;
  SET o_err_fields = JSON_OBJECT();
  IF IFNULL(TRIM(p_reason), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.reason', 'Required'); END IF;
  IF CHAR_LENGTH(TRIM(IFNULL(p_details, ''))) < 10 THEN SET o_err_fields = JSON_SET(o_err_fields, '$.details', 'Tell us what is wrong (at least 10 characters)'); END IF;
  IF p_amount_disputed IS NOT NULL AND (p_amount_disputed <= 0 OR p_amount_disputed > v_total) THEN SET o_err_fields = JSON_SET(o_err_fields, '$.amountDisputed', 'Between ₱0 and the invoice total'); END IF;
  IF p_attachment_file_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM files WHERE file_id = p_attachment_file_id AND uploaded_by = p_user_id AND purpose = 'DISPUTE_ATTACHMENT' AND upload_status = 'Uploaded') THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.attachment', 'Upload the file again');
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;

  START TRANSACTION;
  CALL sp_next_number('DSP', 'DSP-', 6, o_dispute_id);
  INSERT INTO invoice_disputes (dispute_id, client_code, invoice_no, reason, details, amount_disputed, attachment_file_id, submitted_by)
  VALUES (o_dispute_id, v_client, p_invoice_no, TRIM(p_reason), TRIM(p_details), p_amount_disputed, p_attachment_file_id, p_user_id);
  IF p_attachment_file_id IS NOT NULL THEN UPDATE files SET entity_type = 'invoice_dispute', entity_id = o_dispute_id WHERE file_id = p_attachment_file_id; END IF;
  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  SET v_body = CONCAT(p_invoice_no, ' · ', TRIM(p_reason), IF(p_amount_disputed IS NULL, '', CONCAT(' · ₱', FORMAT(p_amount_disputed, 2))));
  CALL sp_notify_user(v_ae, 'billing.dispute', CONCAT('Invoice dispute ', o_dispute_id, ': ', v_cname), v_body, '/billing/invoices');
  CALL sp_notify_roles(JSON_ARRAY('ACCOUNTING'), NULL, 'billing.dispute', CONCAT('Invoice dispute ', o_dispute_id, ': ', v_cname), v_body, '/billing/invoices');
  INSERT INTO invoice_events (invoice_no, event_by, action, note) VALUES (p_invoice_no, p_user_id, 'Disputed', CONCAT(o_dispute_id, ' · ', v_body));
  CALL sp_audit_write(p_user_id, 'CLIENT', 'portal.invoice_dispute', 'invoice', p_invoice_no, NULL, NULL,
       JSON_OBJECT('id', o_dispute_id, 'reason', p_reason, 'amountDisputed', p_amount_disputed), NULL, p_source);
  COMMIT;
END$$

-- GET /portal/soa?from=&to= — statement of account.
-- RS1 header (balance brought forward, period debits / credits, closing balance, scope note) · RS2 rows with running balance
-- RS3 "not on this statement" (posted, unsettled debit memos; e-wallet) · RS4 payments awaiting clearance (provisional receipts)
CREATE PROCEDURE sp_soa_get(IN p_user_id VARCHAR(100), IN p_from DATE, IN p_to DATE, OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_from DATE; DECLARE v_to DATE; DECLARE v_bf DECIMAL(15,2); DECLARE v_debits DECIMAL(15,2); DECLARE v_credits DECIMAL(15,2);
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'The period start is after its end.', o_err_fields = JSON_OBJECT('from', 'Before the end date'); LEAVE proc;
  END IF;
  SET v_to = IFNULL(p_to, fn_manila_today());

  DROP TEMPORARY TABLE IF EXISTS tmp_soa;
  CREATE TEMPORARY TABLE tmp_soa (doc_date DATE, sort_key INT, doc_type VARCHAR(40), doc_no VARCHAR(40), due_date DATE, debit DECIMAL(15,2), credit DECIMAL(15,2), ref VARCHAR(200));
  -- Invoices (debit memos on an invoice are split out as their own rows, so the invoice row shows the original bill)
  INSERT INTO tmp_soa
  SELECT i.invoice_date, 1, 'Invoice', i.invoice_no, i.due_date,
         i.total - IFNULL((SELECT SUM(m.amount) FROM memos m WHERE m.reference_invoice_no = i.invoice_no AND m.memo_type = 'Debit' AND m.status = 'Applied'), 0), 0,
         CONCAT(i.bill_type, IF(i.contract_no IS NULL, '', CONCAT(' · ', i.contract_no)))
    FROM invoices i WHERE i.client_code = v_client AND i.status NOT IN ('Draft','Cancelled');
  INSERT INTO tmp_soa
  SELECT DATE(IFNULL(m.applied_at, m.created_at) + INTERVAL 8 HOUR), 2, 'Debit memo', m.memo_no, NULL, m.amount, 0, CONCAT('On ', m.reference_invoice_no, ' · ', m.reason)
    FROM memos m JOIN invoices i ON i.invoice_no = m.reference_invoice_no AND i.status <> 'Cancelled'
   WHERE m.client_code = v_client AND m.memo_type = 'Debit' AND m.status = 'Applied';
  -- Credit memos applied to an invoice
  INSERT INTO tmp_soa
  SELECT DATE(IFNULL(m.applied_at, m.created_at) + INTERVAL 8 HOUR), 3, 'Credit memo', m.memo_no, NULL, 0, m.amount, CONCAT('Applied to ', IFNULL(m.applied_to, m.reference_invoice_no), ' · ', m.reason)
    FROM memos m WHERE m.client_code = v_client AND m.memo_type = 'Credit' AND m.status = 'Applied'
     AND IFNULL(m.category, '') <> 'Late-encoding correction';
  -- Receipts (Official / Provisional), one row per invoice paid
  INSERT INTO tmp_soa
  SELECT r.receipt_date, 4, IF(r.receipt_type = 'OR', 'Official receipt', 'Provisional receipt'), r.receipt_no, NULL, 0, a.amount,
         CONCAT('Paid ', a.invoice_no, IF(r.pr_no IS NULL, '', CONCAT(' · from ', r.pr_no)), ' · ', r.method)
    FROM receipts r JOIN receipt_applications a ON a.receipt_no = r.receipt_no
   WHERE r.client_code = v_client AND r.status NOT IN ('Cancelled','Bounced') AND (r.receipt_type = 'OR' OR r.or_no IS NULL);

  SELECT IFNULL(MIN(doc_date), v_to) INTO v_from FROM tmp_soa;
  SET v_from = IFNULL(p_from, v_from);
  SELECT IFNULL(SUM(debit - credit), 0) INTO v_bf FROM tmp_soa WHERE doc_date < v_from;
  -- (a TEMPORARY table may be read only once per statement, so the period totals go into variables first)
  SELECT IFNULL(SUM(debit), 0), IFNULL(SUM(credit), 0) INTO v_debits, v_credits FROM tmp_soa WHERE doc_date BETWEEN v_from AND v_to;

  SELECT c.client_code AS clientCode, c.client_name AS clientName, c.billing_name AS billingName, c.billing_cycle AS billingCycle,
         c.address1, c.address2, c.city, c.zip_code AS zipCode, c.country, c.tin, v_from AS periodFrom, v_to AS periodTo, v_bf AS balanceBroughtForward,
         v_debits AS periodDebits, v_credits AS periodCredits, v_bf + v_debits - v_credits AS closingBalance,
         (SELECT IFNULL(SUM(balance), 0) FROM invoices WHERE client_code = v_client AND status <> 'Draft' AND balance > 0) AS balanceDueToday,
         fn_setting_text('fin.soa_scope_note', 'This statement lists invoices, debit and credit memos applied to them, and receipts. Debit memos not yet on an invoice and e-wallet deductions are not on this statement.') AS scopeNote,
         'Provisional receipts become Official receipts once Treasury clears the payment.' AS receiptNote,
         -- Statement number: the last one sent (a new number is reserved only by "Send to my email").
         (SELECT s.soa_no FROM soa_sends s WHERE s.client_code = c.client_code ORDER BY s.sent_at DESC, s.soa_send_id DESC LIMIT 1) AS soaNo,
         (SELECT JSON_OBJECT(
             'current', IFNULL(SUM(IF(x.b = 'current', x.bal, 0)), 0), 'd1_30', IFNULL(SUM(IF(x.b = 'd1_30', x.bal, 0)), 0), 'd31_60', IFNULL(SUM(IF(x.b = 'd31_60', x.bal, 0)), 0),
             'd61_90', IFNULL(SUM(IF(x.b = 'd61_90', x.bal, 0)), 0), 'd91_180', IFNULL(SUM(IF(x.b = 'd91_180', x.bal, 0)), 0), 'd180', IFNULL(SUM(IF(x.b = 'd180', x.bal, 0)), 0),
             'total', IFNULL(SUM(x.bal), 0))
            FROM (SELECT balance AS bal, fn_aging_bucket(fn_days_overdue(due_date)) AS b FROM invoices WHERE client_code = v_client AND status <> 'Draft' AND balance > 0) x) AS aging,
         JSON_OBJECT('address', fn_setting_text('co.address', ''), 'tin', fn_setting_text('co.tin', ''), 'permit', fn_setting_text('co.bir_permit', ''),
                     'payeeBank', fn_setting_text('co.payee_bank', '')) AS company,
         (SELECT JSON_ARRAYAGG(k.contract_no) FROM contracts k WHERE k.client_code = v_client AND k.status IN ('Active','Signed','Notarized')) AS contracts,
         (SELECT w.balance FROM ewallets w WHERE w.client_code = v_client) AS ewalletBalance,
         (SELECT IFNULL(-SUM(t.amount), 0) FROM ewallet_txns t WHERE t.client_code = v_client AND t.txn_type = 'Deduction' AND t.reversed_by_txn_id IS NULL) AS ewalletDeductions
    FROM clients c WHERE c.client_code = v_client;
  SELECT doc_date AS date, doc_type AS docType, doc_no AS docNo, due_date AS due, debit, credit, ref,
         v_bf + SUM(debit - credit) OVER (ORDER BY doc_date, sort_key, doc_no ROWS UNBOUNDED PRECEDING) AS runningBalance
    FROM tmp_soa WHERE doc_date BETWEEN v_from AND v_to ORDER BY doc_date, sort_key, doc_no;
  SELECT memo_no AS memoNo, amount, reason, status, created_at AS createdAt FROM memos WHERE client_code = v_client AND fn_dm_is_unsettled(memo_no) = 1;
  SELECT r.receipt_no AS receiptNo, r.receipt_date AS receiptDate, r.amount, r.method, r.reference, r.deposit_status AS depositStatus
    FROM receipts r WHERE r.client_code = v_client AND r.status = 'Provisional';
  DROP TEMPORARY TABLE tmp_soa;
END$$

-- POST /portal/soa/email — "Send to my email" (and the company billing email when asked). The worker renders the PDF.
CREATE PROCEDURE sp_soa_email(IN p_user_id VARCHAR(100), IN p_from DATE, IN p_to DATE, IN p_copy_billing TINYINT, IN p_source VARCHAR(200),
  OUT o_soa_no VARCHAR(30), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_billing VARCHAR(700); DECLARE v_year CHAR(4) DEFAULT YEAR(fn_manila_today()); DECLARE v_to VARCHAR(100); DECLARE v_copy TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'The period start is after its end.', o_err_fields = JSON_OBJECT('from', 'Before the end date'); LEAVE proc;
  END IF;
  -- PDPA: addresses are ciphertext (not comparable here); soa_sends records a description, the worker skips a duplicate address.
  SELECT ebilling_email INTO v_billing FROM clients WHERE client_code = v_client;
  SET v_copy = (p_copy_billing = 1 AND v_billing IS NOT NULL);
  SET v_to = IF(v_copy, 'Your email + company billing email', 'Your email');
  START TRANSACTION;
  CALL sp_next_number(CONCAT('SOA:', v_year), CONCAT('SOA-', v_year, '-'), 5, o_soa_no);
  INSERT INTO soa_sends (soa_no, client_code, period_from, period_to, channel, sent_to, sent_by) VALUES (o_soa_no, v_client, p_from, p_to, 'Email', v_to, p_user_id);
  CALL sp_outbox_queue('soa', o_soa_no, 'soa.emailed', 'Email', 'Client', 'Your email', v_email, CONCAT('Statement of account ', o_soa_no), NULL,
       JSON_OBJECT('soaNo', o_soa_no, 'clientCode', v_client, 'from', p_from, 'to', p_to, 'template', 'soa_pdf'), 0, v_name);
  IF v_copy THEN
    CALL sp_outbox_queue('soa', o_soa_no, 'soa.emailed', 'Email', 'Client', 'Company billing email', v_billing, CONCAT('Statement of account ', o_soa_no), NULL,
         JSON_OBJECT('soaNo', o_soa_no, 'clientCode', v_client, 'from', p_from, 'to', p_to, 'template', 'soa_pdf'), 0, NULL);
  END IF;
  CALL sp_audit_write(p_user_id, 'CLIENT', 'portal.soa_emailed', 'client', v_client, NULL, NULL,
       JSON_OBJECT('soaNo', o_soa_no, 'to', v_to, 'from', IFNULL(p_from, 'start'), 'toDate', IFNULL(p_to, 'today')), NULL, p_source);
  COMMIT;
  SELECT o_soa_no AS soaNo, p_from AS periodFrom, p_to AS periodTo;
  SELECT recipient_label AS recipient, recipient_name AS recipientName, to_address AS `to`, status FROM message_outbox WHERE entity_type = 'soa' AND entity_id = o_soa_no;
  SELECT memo_no AS memoNo, amount FROM memos WHERE client_code = v_client AND fn_dm_is_unsettled(memo_no) = 1;
END$$

-- GET /portal/hire-coverage — every billable day of every hire invoiced exactly once (Timeline 3 "earlier on-hire rent").
-- Billable days: Gate Out day to Gate In day inclusive (Manila dates), up to the contract's last invoiced lease period end (cut-off).
-- Node derives status per row: missingDays → 'Gap', billedTwiceDays → 'Billed twice', else 'Every day invoiced once'.
CREATE PROCEDURE sp_hire_coverage(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_today DATE DEFAULT fn_manila_today(); DECLARE v_start DATE;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT IFNULL(MIN(fn_manila_date(actual_event_at)), v_today) INTO v_start FROM gate_passes WHERE client_code = v_client AND direction = 'OUT';
  SET SESSION cte_max_recursion_depth = GREATEST(1000, DATEDIFF(v_today, v_start) + 10);

  WITH RECURSIVE
  cal AS (SELECT v_start AS d UNION ALL SELECT d + INTERVAL 1 DAY FROM cal WHERE d < v_today),
  hire AS (
    SELECT go.gate_pass_no AS gate_out, go.chassis_no, go.contract_no, fn_manila_date(go.actual_event_at) AS out_day,
           gi.gate_pass_no AS gate_in, fn_manila_date(gi.actual_event_at) AS in_day,
           IFNULL((SELECT MAX(i.period_end) FROM invoices i WHERE i.contract_no = go.contract_no AND i.status NOT IN ('Draft','Cancelled')
                     AND EXISTS (SELECT 1 FROM invoice_lines l WHERE l.invoice_no = i.invoice_no AND l.line_type = 'Lease')), DATE('1900-01-01')) AS cutoff
      FROM gate_passes go LEFT JOIN gate_passes gi ON gi.gate_pass_no = go.paired_gate_pass_no AND gi.direction = 'IN'
     WHERE go.client_code = v_client AND go.direction = 'OUT'),
  due AS (   -- billable days up to the cut-off
    SELECT h.gate_out, c.d FROM hire h JOIN cal c ON c.d BETWEEN h.out_day AND LEAST(IFNULL(h.in_day, h.cutoff), h.cutoff)),
  seen AS (  -- days on lease lines for the same unit and contract, inside the hire window (one row per invoice line-day)
    SELECT h.gate_out, c.d, l.invoice_no
      FROM hire h
      JOIN invoice_lines l ON l.chassis_no = h.chassis_no AND l.line_type = 'Lease' AND l.date_from IS NOT NULL AND l.date_to IS NOT NULL
      JOIN invoices i ON i.invoice_no = l.invoice_no AND i.contract_no = h.contract_no AND i.status NOT IN ('Draft','Cancelled')
      JOIN cal c ON c.d BETWEEN GREATEST(l.date_from, h.out_day) AND LEAST(l.date_to, IFNULL(h.in_day, v_today)))
  SELECT h.chassis_no AS unitId, h.contract_no AS contractNo, h.gate_out AS gateOut, h.out_day AS outDay, h.gate_in AS gateIn, h.in_day AS inDay,
         IF(h.cutoff = DATE('1900-01-01'), NULL, h.cutoff) AS cutOff,
         (SELECT COUNT(*) FROM due u WHERE u.gate_out = h.gate_out) AS billableToCutOff,
         (SELECT COUNT(DISTINCT s.d) FROM seen s WHERE s.gate_out = h.gate_out) AS invoicedDays,
         (SELECT JSON_ARRAYAGG(x.invoice_no) FROM (SELECT DISTINCT s.gate_out, s.invoice_no FROM seen s) x WHERE x.gate_out = h.gate_out) AS invoices,
         (SELECT JSON_ARRAYAGG(u.d) FROM due u WHERE u.gate_out = h.gate_out
             AND NOT EXISTS (SELECT 1 FROM seen s WHERE s.gate_out = u.gate_out AND s.d = u.d)) AS missingDays,
         (SELECT JSON_ARRAYAGG(y.d) FROM (SELECT s.gate_out, s.d FROM seen s GROUP BY s.gate_out, s.d HAVING COUNT(*) > 1) y WHERE y.gate_out = h.gate_out) AS billedTwiceDays,
         IF(h.in_day IS NOT NULL AND h.in_day <= h.cutoff, 0,
            (SELECT COUNT(*) FROM cal c WHERE c.d > h.cutoff AND c.d >= h.out_day AND c.d <= IFNULL(h.in_day, v_today))) AS accruingDays
    FROM hire h ORDER BY h.out_day, h.gate_out;
END$$

DELIMITER ;
