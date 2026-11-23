-- =====================================================================================================
-- 08_sp_ewallet_bond.sql : E-wallet ledger, top-up requests (Submitted → Confirmed by Treasury → Posted),
--                          cash bond list, BR-14 refund preview, withdrawal request (four-step approval)
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_ewallet_ledger;
DROP PROCEDURE IF EXISTS sp_topup_list;
DROP PROCEDURE IF EXISTS sp_topup_create;
DROP PROCEDURE IF EXISTS sp_portal_cash_bonds;
DROP PROCEDURE IF EXISTS sp_bond_refund_preview;
DROP PROCEDURE IF EXISTS sp_bond_withdrawal_request;

DELIMITER $$

-- GET /portal/ewallet?category=&from=&to=&page=&pageSize=  (pageSize=0: all rows)
-- RS1 wallet {balance, minimum, state, ranges, pending top-ups, billing entity for the pay-to account} · RS2 ledger rows · RS3 {total}
CREATE PROCEDURE sp_ewallet_ledger(IN p_user_id VARCHAR(100), IN p_category VARCHAR(40), IN p_from DATE, IN p_to DATE, IN p_page INT, IN p_page_size INT,
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  -- p_page_size = 0 → the whole ledger (the portal E-wallet page filters and pages in the browser)
  DECLARE v_size INT DEFAULT IF(p_page_size = 0, 1000000, LEAST(GREATEST(IFNULL(p_page_size, 10), 1), 100));
  DECLARE v_offset INT DEFAULT IF(p_page_size = 0, 0, (GREATEST(IFNULL(p_page, 1), 1) - 1) * LEAST(GREATEST(IFNULL(p_page_size, 10), 1), 100));
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  SELECT c.client_code AS clientCode, w.balance, w.minimum_balance AS minimumBalance,
         IF(w.client_code IS NULL, NULL, fn_wallet_state(w.balance, w.minimum_balance)) AS state,
         ROUND(w.minimum_balance * fn_setting_num('ewl.near_factor', 1.25), 2) AS healthyFrom,
         (SELECT COUNT(*) FROM topup_requests t WHERE t.client_code = c.client_code AND t.status IN ('Submitted','Confirmed by Treasury')) AS pendingTopups,
         (SELECT IFNULL(SUM(t.amount), 0) FROM topup_requests t WHERE t.client_code = c.client_code AND t.status IN ('Submitted','Confirmed by Treasury')) AS pendingTopupTotal,
         b.billing_entity AS billingEntity, CONCAT('EW-', c.client_code) AS paymentReference,
         JSON_OBJECT('min', fn_setting_num('ewl.topup_min', 500), 'max', fn_setting_num('ewl.topup_max', 5000000),
                     'maxAgeDays', fn_setting_num('ewl.topup_max_age_days', 60), 'maxFileMb', fn_setting_num('files.max_mb.TOPUP_PROOF', 5)) AS topupRules
    FROM clients c LEFT JOIN ewallets w ON w.client_code = c.client_code JOIN branches b ON b.branch_code = c.branch_code
   WHERE c.client_code = v_client;
  SELECT t.txn_id AS id, t.txn_at AS at, t.txn_type AS type, t.category, t.amount, t.balance_after AS balanceAfter, t.reference_type AS referenceType,
         t.reference_id AS referenceId, t.receipt_no AS receiptNo, t.treasury_ref AS treasuryRef, t.posted_directly_by_treasury AS postedByTreasury,
         t.reverses_txn_id AS reversesId, t.reversed_by_txn_id AS reversedById, t.reason,
         (SELECT m.memo_no FROM memos m WHERE m.memo_no = t.reference_id OR m.rescue_no = t.reference_id LIMIT 1) AS debitMemoNo
    FROM ewallet_txns t
   WHERE t.client_code = v_client AND (p_category IS NULL OR p_category = '' OR t.category = p_category)
     AND (p_from IS NULL OR fn_manila_date(t.txn_at) >= p_from) AND (p_to IS NULL OR fn_manila_date(t.txn_at) <= p_to)
   ORDER BY t.txn_at DESC, t.txn_id DESC LIMIT v_offset, v_size;
  SELECT COUNT(*) AS total FROM ewallet_txns t
   WHERE t.client_code = v_client AND (p_category IS NULL OR p_category = '' OR t.category = p_category)
     AND (p_from IS NULL OR fn_manila_date(t.txn_at) >= p_from) AND (p_to IS NULL OR fn_manila_date(t.txn_at) <= p_to);
END$$

-- GET /portal/topups — RS1 requests (with steps) · RS2 who was told per request
CREATE PROCEDURE sp_topup_list(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT t.topup_id AS id, t.amount, t.transfer_date AS transferDate, t.method, t.sending_bank AS sendingBank, t.payment_ref AS paymentRef,
         t.check_no AS checkNo, t.check_date AS checkDate, t.check_bank AS checkBank, t.proof_file_id AS proofFileId, t.remarks, t.resubmit_of AS resubmitOf,
         t.status, t.submitted_at AS submittedAt, t.confirmed_at AS confirmedAt, t.posted_at AS postedAt, t.receipt_no AS receiptNo, t.txn_id AS txnId,
         t.rejected_at AS rejectedAt, t.reject_reason AS rejectReason,
         (t.status = 'Rejected' AND NOT EXISTS (SELECT 1 FROM topup_requests x WHERE x.resubmit_of = t.topup_id)) AS canResubmit,
         JSON_ARRAY(JSON_OBJECT('step', 'Submitted', 'at', t.submitted_at),
                    JSON_OBJECT('step', 'Confirmed by Treasury', 'at', t.confirmed_at),
                    JSON_OBJECT('step', 'Posted', 'at', t.posted_at)) AS steps
    FROM topup_requests t WHERE t.client_code = v_client ORDER BY t.submitted_at DESC;
  SELECT m.entity_id AS topupId, m.queued_at AS at, m.channel, m.audience, m.recipient_label AS recipient, m.recipient_name AS recipientName, m.to_address AS `to`, m.status
    FROM message_outbox m JOIN topup_requests t ON t.topup_id = m.entity_id AND t.client_code = v_client
   WHERE m.entity_type = 'topup' ORDER BY m.message_id;
END$$

-- POST /portal/topups — the client tells Treasury it has transferred funds; Treasury confirms, Accounting posts.
CREATE PROCEDURE sp_topup_create(IN p_user_id VARCHAR(100), IN p_amount DECIMAL(15,2), IN p_transfer_date DATE, IN p_method VARCHAR(50), IN p_sending_bank VARCHAR(100),
  IN p_reference VARCHAR(80), IN p_proof_file_id CHAR(36), IN p_remarks VARCHAR(200), IN p_resubmit_of VARCHAR(20),
  IN p_check_no VARCHAR(30), IN p_check_date DATE, IN p_check_bank VARCHAR(100), IN p_source VARCHAR(200),
  OUT o_topup_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_today DATE DEFAULT fn_manila_today(); DECLARE v_min DECIMAL(15,2) DEFAULT fn_setting_num('ewl.topup_min', 500);
  DECLARE v_max DECIMAL(15,2) DEFAULT fn_setting_num('ewl.topup_max', 5000000); DECLARE v_age INT DEFAULT fn_setting_num('ewl.topup_max_age_days', 60);
  DECLARE v_by_check TINYINT DEFAULT (LOWER(IFNULL(p_method, '')) REGEXP '\\bcheck\\b');
  DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100); DECLARE v_body TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Portal only'; LEAVE proc; END IF;

  SET o_err_fields = JSON_OBJECT();
  IF p_amount IS NULL OR p_amount <= 0 THEN SET o_err_fields = JSON_SET(o_err_fields, '$.amount', 'Enter the amount you paid');
  ELSEIF p_amount < v_min THEN SET o_err_fields = JSON_SET(o_err_fields, '$.amount', CONCAT('At least ₱', FORMAT(v_min, 0)));
  ELSEIF p_amount > v_max THEN SET o_err_fields = JSON_SET(o_err_fields, '$.amount', CONCAT('At most ₱', FORMAT(v_max, 0), ' per request')); END IF;
  IF p_transfer_date IS NULL THEN SET o_err_fields = JSON_SET(o_err_fields, '$.transferDate', 'Required');
  ELSEIF p_transfer_date > v_today THEN SET o_err_fields = JSON_SET(o_err_fields, '$.transferDate', 'Cannot be in the future');
  ELSEIF p_transfer_date < v_today - INTERVAL v_age DAY THEN SET o_err_fields = JSON_SET(o_err_fields, '$.transferDate', CONCAT('Within the last ', v_age, ' days')); END IF;
  IF IFNULL(TRIM(p_method), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.method', 'Required'); END IF;
  IF IFNULL(TRIM(p_reference), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.reference', 'Required'); END IF;
  IF NOT EXISTS (SELECT 1 FROM files WHERE file_id = p_proof_file_id AND uploaded_by = p_user_id AND purpose = 'TOPUP_PROOF' AND upload_status = 'Uploaded' AND entity_id IS NULL) THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.proofFile', 'Upload the bank slip or transfer confirmation');
  END IF;
  IF CHAR_LENGTH(IFNULL(p_remarks, '')) > 200 THEN SET o_err_fields = JSON_SET(o_err_fields, '$.remarks', 'Max 200 characters'); END IF;
  IF v_by_check = 1 THEN
    IF IFNULL(TRIM(p_check_no), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.checkNo', 'Check number is required'); END IF;
    IF p_check_date IS NULL THEN SET o_err_fields = JSON_SET(o_err_fields, '$.checkDate', 'Check date is required');
    ELSEIF p_check_date > v_today + INTERVAL 180 DAY THEN SET o_err_fields = JSON_SET(o_err_fields, '$.checkDate', 'Within the next 180 days'); END IF;
    IF IFNULL(TRIM(p_check_bank), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.checkBank', 'Drawee bank is required'); END IF;
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;
  IF EXISTS (SELECT 1 FROM topup_requests WHERE client_code = v_client AND payment_ref_norm = UPPER(TRIM(p_reference)) AND status <> 'Rejected') THEN
    SET o_err_code = 'DUPLICATE', o_err_msg = CONCAT('A top-up with reference ', TRIM(p_reference), ' was already sent.'), o_err_fields = JSON_OBJECT('reference', 'Already used on another request'); LEAVE proc;
  END IF;
  IF p_resubmit_of IS NOT NULL AND NOT EXISTS (SELECT 1 FROM topup_requests WHERE topup_id = p_resubmit_of AND client_code = v_client AND status = 'Rejected') THEN
    SET o_err_code = 'INVALID_STATE', o_err_msg = 'Only a rejected request can be resubmitted.'; LEAVE proc;
  END IF;

  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  START TRANSACTION;
  CALL sp_next_number('TU', 'TU-', 6, o_topup_id);
  INSERT INTO topup_requests (topup_id, client_code, amount, transfer_date, method, sending_bank, payment_ref, check_no, check_date, check_bank, proof_file_id, remarks, resubmit_of, status, submitted_by)
  VALUES (o_topup_id, v_client, ROUND(p_amount, 2), p_transfer_date, TRIM(p_method), NULLIF(TRIM(p_sending_bank), ''), TRIM(p_reference),
          IF(v_by_check = 1, TRIM(p_check_no), NULL), IF(v_by_check = 1, p_check_date, NULL), IF(v_by_check = 1, TRIM(p_check_bank), NULL),
          p_proof_file_id, NULLIF(TRIM(p_remarks), ''), p_resubmit_of, 'Submitted', p_user_id);
  UPDATE files SET entity_type = 'topup', entity_id = o_topup_id WHERE file_id = p_proof_file_id;
  SET v_body = CONCAT('₱', FORMAT(p_amount, 2), ' · ', TRIM(p_method), ' · ref ', TRIM(p_reference), ' · transferred ', p_transfer_date,
                      IF(p_resubmit_of IS NULL, '', CONCAT(' · resubmission of ', p_resubmit_of)));
  CALL sp_outbox_queue_roles('topup', o_topup_id, 'ewallet.topup', JSON_ARRAY('TREASURY'), NULL, 'Treasury (to confirm the funds)',
       CONCAT('Top-up ', o_topup_id, ' to confirm: ', v_cname), v_body, NULL);
  CALL sp_outbox_queue('topup', o_topup_id, 'ewallet.topup', 'Email', 'Delbros', 'Account Executive',
       (SELECT email FROM users WHERE user_id = v_ae), CONCAT('Top-up ', o_topup_id, ': ', v_cname), v_body, NULL, 0, (SELECT full_name FROM users WHERE user_id = v_ae));
  CALL sp_outbox_queue('topup', o_topup_id, 'ewallet.topup', 'Email', 'Client', 'Confirmation to you', v_email,
       CONCAT('Top-up request ', o_topup_id, ' received — Treasury will confirm'), v_body, NULL, 0, v_name);
  CALL sp_notify_roles(JSON_ARRAY('TREASURY'), NULL, 'ewallet.topup', CONCAT('Top-up ', o_topup_id, ' to confirm: ', v_cname), v_body, CONCAT('/ewallet/', v_client));
  CALL sp_notify_user(v_ae, 'ewallet.topup', CONCAT('Top-up ', o_topup_id, ': ', v_cname), v_body, CONCAT('/ewallet/', v_client));
  CALL sp_audit_write(p_user_id, 'CLIENT', 'ewallet.topup_requested', 'ewallet', v_client, NULL, NULL,
       JSON_OBJECT('id', o_topup_id, 'amount', p_amount, 'method', p_method, 'reference', p_reference, 'transferDate', p_transfer_date, 'resubmitOf', p_resubmit_of), NULL, p_source);
  COMMIT;
  SELECT topup_id AS id, amount, transfer_date AS transferDate, method, payment_ref AS paymentRef, status, submitted_at AS submittedAt, resubmit_of AS resubmitOf
    FROM topup_requests WHERE topup_id = o_topup_id;
  SELECT queued_at AS at, channel, audience, recipient_label AS recipient, recipient_name AS recipientName, to_address AS `to`, status FROM message_outbox
   WHERE entity_type = 'topup' AND entity_id = o_topup_id ORDER BY message_id;
END$$

-- GET /portal/cash-bonds — RS1 bonds with the BR-14 preview · RS2 withdrawal requests with stage, approvals, refund, breakdowns
CREATE PROCEDURE sp_portal_cash_bonds(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_done INT DEFAULT 0; DECLARE v_bond VARCHAR(20);
  DECLARE b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short DECIMAL(15,2); DECLARE b_src JSON; DECLARE b_cno VARCHAR(30); DECLARE b_cst VARCHAR(20); DECLARE b_cexp DATE; DECLARE b_ended TINYINT;
  DECLARE cur CURSOR FOR SELECT bond_id FROM cash_bonds WHERE client_code = v_client;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_bond_preview;
  CREATE TEMPORARY TABLE tmp_bond_preview (bond_id VARCHAR(20) PRIMARY KEY, preview JSON);
  OPEN cur;
  b: LOOP
    FETCH cur INTO v_bond;
    IF v_done = 1 THEN LEAVE b; END IF;
    CALL sp_bond_refund_compute(v_bond, b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short, b_src, b_cno, b_cst, b_cexp, b_ended);
    SET v_done = 0;  -- a warning raised inside the call must not end the loop
    INSERT INTO tmp_bond_preview VALUES (v_bond, JSON_OBJECT('bond', b_bond, 'unpaid', b_unpaid, 'negativeWallet', b_neg, 'pendingDm', b_pdm, 'postedUnsettledDm', b_udm,
      'openDm', b_pdm + b_udm, 'deductions', b_ded, 'refundable', b_ref, 'shortfall', b_short, 'sources', b_src, 'contractNo', b_cno, 'contractStatus', b_cst,
      'contractExpiry', b_cexp, 'contractEnded', b_ended = 1,
      'contractBond', (SELECT cash_deposit FROM contracts WHERE contract_no = b_cno)));
  END LOOP;
  CLOSE cur;

  SELECT b.bond_id AS id, b.contract_no AS contractNo, b.amount, b.date_received AS dateReceived, b.receipt_ref AS receiptRef, b.payment_method AS paymentMethod,
         b.status, b.outcome_kind AS outcomeKind, b.outcome_at AS outcomeAt, b.outcome_amount AS outcomeAmount, b.outcome_reference AS outcomeReference,
         b.outcome_note AS outcomeNote, b.outcome_to_contract AS outcomeToContract, p.preview
    FROM cash_bonds b JOIN tmp_bond_preview p ON p.bond_id = b.bond_id ORDER BY b.date_received DESC;
  DROP TEMPORARY TABLE tmp_bond_preview;

  SELECT w.withdrawal_id AS id, w.bond_id AS bondId, w.amount, w.reason, w.early_exception AS earlyException, w.requested_at AS requestedAt, ru.full_name AS requestedByName,
         w.status, w.rejected_at AS rejectedAt, w.reject_reason AS rejectReason,
         CASE WHEN w.status = 'Refunded' THEN 'Refunded'
              WHEN w.status = 'Rejected' THEN CONCAT('Rejected at ', IFNULL((SELECT s.label FROM workflow_steps s WHERE s.workflow_id = w.workflow_id AND s.decision = 'Rejected' LIMIT 1), 'review'))
              WHEN w.status LIKE 'Approved%' THEN 'Approved — Accounting to pay the refund'
              ELSE CONCAT('With ', IFNULL((SELECT s.label FROM workflows f JOIN workflow_steps s ON s.workflow_id = f.workflow_id AND s.step_no = f.current_step WHERE f.workflow_id = w.workflow_id), 'Delbros')) END AS stage,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('label', s.label,
                   'status', IF(s.decision = 'Pending', IF(f.status = 'Pending' AND s.step_no = f.current_step, 'Reviewing', 'Waiting'), s.decision),
                   'by', (SELECT full_name FROM users WHERE user_id = s.decided_by), 'at', s.decided_at))
            FROM workflow_steps s JOIN workflows f ON f.workflow_id = s.workflow_id WHERE s.workflow_id = w.workflow_id) AS steps,
         IF(w.refund_date IS NULL, NULL, JSON_OBJECT('method', w.refund_method, 'date', w.refund_date, 'reference', w.refund_reference,
                                                      'by', (SELECT full_name FROM users WHERE user_id = w.refund_by))) AS refund,
         (SELECT JSON_OBJECT('bond', k.bond, 'unpaid', k.unpaid, 'negativeWallet', k.negative_wallet, 'pendingDm', k.pending_dm, 'postedUnsettledDm', k.posted_unsettled_dm,
                             'deductions', k.deductions, 'refundable', k.refundable, 'sources', k.sources_json)
            FROM cash_bond_withdrawal_breakdowns k WHERE k.withdrawal_id = w.withdrawal_id AND k.stage = 'Request') AS breakdown,
         (SELECT JSON_OBJECT('at', k.computed_at, 'deductions', k.deductions, 'refundable', k.refundable, 'sources', k.sources_json)
            FROM cash_bond_withdrawal_breakdowns k WHERE k.withdrawal_id = w.withdrawal_id AND k.stage = 'Recheck') AS recheck
    FROM cash_bond_withdrawals w JOIN cash_bonds b ON b.bond_id = w.bond_id LEFT JOIN users ru ON ru.user_id = w.requested_by
   WHERE b.client_code = v_client ORDER BY w.requested_at DESC;
END$$

-- GET /portal/cash-bonds/:bondId/refund-preview — what could be withdrawn today (BR-14)
CREATE PROCEDURE sp_bond_refund_preview(IN p_user_id VARCHAR(100), IN p_bond_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short DECIMAL(15,2); DECLARE b_src JSON; DECLARE b_cno VARCHAR(30); DECLARE b_cst VARCHAR(20); DECLARE b_cexp DATE; DECLARE b_ended TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF NOT EXISTS (SELECT 1 FROM cash_bonds WHERE bond_id = p_bond_id AND client_code = v_client) THEN SET o_err_code = 'NOT_FOUND', o_err_msg = 'Cash bond not found.'; LEAVE proc; END IF;
  CALL sp_bond_refund_compute(p_bond_id, b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short, b_src, b_cno, b_cst, b_cexp, b_ended);
  SELECT p_bond_id AS bondId, b_bond AS bond, b_unpaid AS unpaid, b_neg AS negativeWallet, b_pdm AS pendingDm, b_udm AS postedUnsettledDm, b_pdm + b_udm AS openDm,
         b_ded AS deductions, b_ref AS refundable, b_short AS shortfall, b_src AS sources, b_cno AS contractNo, b_cst AS contractStatus, b_cexp AS contractExpiry, b_ended AS contractEnded,
         (SELECT cash_deposit FROM contracts WHERE contract_no = b_cno) AS contractBond;
END$$

-- POST /portal/cash-bonds/:bondId/withdrawals — recalculated now; refundable only at contract end unless p_early_exception (flagged).
-- Approval chain: Credit & Collection → Finance → Accounting → Admin; the breakdown is stored with the request.
CREATE PROCEDURE sp_bond_withdrawal_request(IN p_user_id VARCHAR(100), IN p_bond_id VARCHAR(20), IN p_amount DECIMAL(15,2), IN p_reason VARCHAR(1000),
  IN p_early_exception TINYINT, IN p_source VARCHAR(200),
  OUT o_withdrawal_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_wf VARCHAR(20); DECLARE v_cname VARCHAR(200);
  DECLARE b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short DECIMAL(15,2); DECLARE b_src JSON; DECLARE b_cno VARCHAR(30); DECLARE b_cst VARCHAR(20); DECLARE b_cexp DATE; DECLARE b_ended TINYINT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  START TRANSACTION;
  SELECT status INTO v_status FROM cash_bonds WHERE bond_id = p_bond_id AND client_code = v_client FOR UPDATE;
  IF v_status IS NULL THEN ROLLBACK; SET o_err_code = 'NOT_FOUND', o_err_msg = 'Cash bond not found.'; LEAVE proc; END IF;
  CALL sp_bond_refund_compute(p_bond_id, b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_short, b_src, b_cno, b_cst, b_cexp, b_ended);
  IF v_status <> 'Held' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = 'A withdrawal is already in progress for this bond.'; LEAVE proc; END IF;
  IF b_ref <= 0 THEN
    ROLLBACK; SET o_err_code = 'NOTHING_REFUNDABLE', o_err_msg = CONCAT('Nothing is refundable now — what you owe (₱', FORMAT(b_ded, 2), ') is at least the bond (₱', FORMAT(b_bond, 2), ') (BR-14).'); LEAVE proc;
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Enter a withdrawal amount greater than zero.', o_err_fields = JSON_OBJECT('amount', 'Must be greater than zero'); LEAVE proc; END IF;
  IF IFNULL(TRIM(p_reason), '') = '' THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'A reason is required.', o_err_fields = JSON_OBJECT('reason', 'Required'); LEAVE proc; END IF;
  IF p_amount > b_ref THEN
    ROLLBACK; SET o_err_code = 'THRESHOLD_EXCEEDED', o_err_msg = CONCAT('Withdrawal exceeds the refundable amount (₱', FORMAT(b_ref, 2), ').'), o_err_fields = JSON_OBJECT('amount', 'Exceeds refundable amount'); LEAVE proc;
  END IF;
  IF b_ended = 0 AND IFNULL(p_early_exception, 0) = 0 THEN
    ROLLBACK; SET o_err_code = 'BR14_CONTRACT_ACTIVE', o_err_msg = CONCAT('Contract ', b_cno, ' is ', b_cst, '; the bond is refundable at contract end (BR-14). Request an early-withdrawal exception instead.'); LEAVE proc;
  END IF;

  SELECT client_name INTO v_cname FROM clients WHERE client_code = v_client;
  CALL sp_workflow_start('CASH_BOND_WITHDRAWAL', CONCAT('Cash bond withdrawal', IF(b_ended = 0, ' (EARLY — exception)', ''), ' — ', v_cname), 'cashbond', p_bond_id, p_amount, NULL, p_user_id,
       JSON_ARRAY(JSON_OBJECT('label', 'Credit & Collection', 'roles', JSON_ARRAY('CNC_OFFICER')), JSON_OBJECT('label', 'Finance', 'roles', JSON_ARRAY('FINANCE_MANAGER')),
                  JSON_OBJECT('label', 'Accounting', 'roles', JSON_ARRAY('ACCOUNTING')), JSON_OBJECT('label', 'Admin', 'roles', JSON_ARRAY('SYS_ADMIN'))), v_wf);
  CALL sp_next_number('CBW', 'CBW-', 6, o_withdrawal_id);
  INSERT INTO cash_bond_withdrawals (withdrawal_id, bond_id, amount, reason, refundable_at_request, early_exception, workflow_id, status, requested_by)
  VALUES (o_withdrawal_id, p_bond_id, p_amount, TRIM(p_reason), b_ref, b_ended = 0, v_wf, 'Pending', p_user_id);
  INSERT INTO cash_bond_withdrawal_breakdowns (withdrawal_id, stage, bond, unpaid, negative_wallet, pending_dm, posted_unsettled_dm, deductions, refundable, sources_json)
  VALUES (o_withdrawal_id, 'Request', b_bond, b_unpaid, b_neg, b_pdm, b_udm, b_ded, b_ref, b_src);
  UPDATE cash_bonds SET status = 'Withdrawal Pending', row_version = row_version + 1 WHERE bond_id = p_bond_id;
  CALL sp_notify_client_users(v_client, 'cashbond.withdrawal', CONCAT('Cash bond withdrawal ', o_withdrawal_id, ' requested'),
       CONCAT('₱', FORMAT(p_amount, 2), ' from the ', IFNULL(b_cno, ''), ' bond — with Credit & Collection for review.'), '/client/ewallet#cash-bond');
  CALL sp_outbox_queue('cashbond', o_withdrawal_id, 'cashbond.withdrawal', 'Email', 'Client', 'Confirmation to you', v_email, CONCAT('Cash bond withdrawal ', o_withdrawal_id, ' requested'),
       CONCAT('₱', FORMAT(p_amount, 2), ' from the ', IFNULL(b_cno, ''), ' bond — with Credit & Collection for review.'), NULL, 0, v_name);
  CALL sp_audit_write(p_user_id, 'CLIENT', 'cashbond.withdrawal_requested', 'cashbond', p_bond_id, NULL, JSON_OBJECT('status', 'Held'),
       JSON_OBJECT('id', o_withdrawal_id, 'amount', p_amount, 'earlyException', b_ended = 0, 'refundable', b_ref, 'deductions', b_ded), TRIM(p_reason), p_source);
  COMMIT;
END$$

DELIMITER ;
