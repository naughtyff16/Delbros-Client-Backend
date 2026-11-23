-- =====================================================================================================
-- 11_sp_jobs.sql : scheduled jobs and the email outbox worker
-- Run by the backend's job worker on EC2 (node-cron or EventBridge Scheduler → SQS → worker), never by the browser.
-- In the mock these ran only when someone opened a screen; here they run on a timer (roadmap layer 7).
--   every 5 min : sp_job_expire_ewas
--   hourly      : sp_job_auto_hold
--   daily 00:10 : sp_job_expire_contracts, sp_job_cleanup   (Manila time)
--   every 30 s  : sp_outbox_claim → send via SES → sp_outbox_mark
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_job_expire_ewas;
DROP PROCEDURE IF EXISTS sp_job_auto_hold;
DROP PROCEDURE IF EXISTS sp_job_expire_contracts;
DROP PROCEDURE IF EXISTS sp_job_cleanup;
DROP PROCEDURE IF EXISTS sp_outbox_claim;
DROP PROCEDURE IF EXISTS sp_outbox_mark;

DELIMITER $$

-- BR-06: an Active or Partially Used EWA expires at valid_until; units not yet released lapse.
CREATE PROCEDURE sp_job_expire_ewas(OUT o_count INT)
BEGIN
  DECLARE v_done INT DEFAULT 0; DECLARE v_eu VARCHAR(20); DECLARE v_branch VARCHAR(10); DECLARE v_lapsed INT;
  DECLARE cur CURSOR FOR SELECT eu_no, branch_code FROM ewas WHERE status IN ('Active','Partially Used') AND valid_until < UTC_TIMESTAMP(3) FOR UPDATE;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_count = 0;
  START TRANSACTION;
  OPEN cur;
  l: LOOP
    FETCH cur INTO v_eu, v_branch;
    IF v_done = 1 THEN LEAVE l; END IF;
    SELECT IFNULL(SUM(GREATEST(0, l.qty - (SELECT COUNT(*) FROM ewa_line_chassis c WHERE c.eu_no = l.eu_no AND c.equipment_type = l.equipment_type))), 0)
      INTO v_lapsed FROM ewa_lines l WHERE l.eu_no = v_eu;
    UPDATE ewas SET status = 'Expired', expired_lapsed_units = v_lapsed, row_version = row_version + 1 WHERE eu_no = v_eu;
    CALL sp_audit_write('system', 'SYSTEM', 'ewa.expired', 'ewa', v_eu, v_branch, NULL, JSON_OBJECT('status', 'Expired', 'lapsedUnits', v_lapsed), 'Validity ended (BR-06)', 'System job');
    SET o_count = o_count + 1, v_done = 0;
  END LOOP;
  CLOSE cur;
  COMMIT;
END$$

-- BR-02: an Active client with an invoice more than cnc.hold_threshold_days past due goes on hold.
CREATE PROCEDURE sp_job_auto_hold(OUT o_count INT)
BEGIN
  DECLARE v_done INT DEFAULT 0; DECLARE v_client VARCHAR(20); DECLARE v_name VARCHAR(200); DECLARE v_ae VARCHAR(100);
  DECLARE v_inv VARCHAR(30); DECLARE v_days INT; DECLARE v_out DECIMAL(15,2); DECLARE v_rehold TINYINT;
  DECLARE v_threshold INT DEFAULT fn_setting_num('cnc.hold_threshold_days', 30);
  DECLARE cur CURSOR FOR
    SELECT c.client_code, c.client_name, c.ae_user_id FROM clients c
     WHERE c.status = 'Active' AND EXISTS (SELECT 1 FROM invoices i WHERE i.client_code = c.client_code AND i.status <> 'Draft' AND i.balance > 0 AND fn_days_overdue(i.due_date) > v_threshold);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_count = 0;
  OPEN cur;
  l: LOOP
    FETCH cur INTO v_client, v_name, v_ae;
    IF v_done = 1 THEN LEAVE l; END IF;
    START TRANSACTION;
    SELECT invoice_no, fn_days_overdue(due_date) INTO v_inv, v_days FROM invoices
     WHERE client_code = v_client AND status <> 'Draft' AND balance > 0 AND fn_days_overdue(due_date) > v_threshold ORDER BY due_date LIMIT 1;
    SELECT IFNULL(SUM(balance), 0) INTO v_out FROM invoices WHERE client_code = v_client AND status <> 'Draft';
    SELECT EXISTS (SELECT 1 FROM hold_events WHERE client_code = v_client AND event_type = 'Reactivated') INTO v_rehold;
    UPDATE clients SET status = 'Hold', row_version = row_version + 1 WHERE client_code = v_client AND status = 'Active';
    INSERT INTO hold_events (client_code, event_type, event_by, outstanding, days_overdue, invoice_no) VALUES (v_client, IF(v_rehold, 'Re-Hold', 'Auto Hold'), 'system', v_out, v_days, v_inv);
    CALL sp_notify_roles(JSON_ARRAY('CNC_OFFICER','CNC_MANAGER'), NULL, 'client.hold.applied', CONCAT('Credit hold: ', v_name),
         CONCAT('Invoice ', v_inv, ' is ', v_days, ' days past due. Release, gate pass, repair and new services are blocked.'), CONCAT('/credit/', v_client));
    CALL sp_notify_user(v_ae, 'client.hold.applied', CONCAT('Credit hold: ', v_name), CONCAT('Invoice ', v_inv, ' is ', v_days, ' days past due.'), CONCAT('/credit/', v_client));
    CALL sp_notify_client_users(v_client, 'client.hold.applied', 'Your account is on hold',
         CONCAT('Invoice ', v_inv, ' is ', v_days, ' days past due. New EWAs and services are blocked until the overdue balance is settled (BR-01).'), '/client');
    CALL sp_audit_write('system', 'SYSTEM', 'client.hold.applied', 'client', v_client, NULL, JSON_OBJECT('status', 'Active'), JSON_OBJECT('status', 'Hold'), CONCAT('Auto hold (BR-02) — ', v_inv), 'System job');
    COMMIT;
    SET o_count = o_count + 1, v_done = 0;
  END LOOP;
  CLOSE cur;
END$$

-- DBL-CLT-011: renewal notices 3, 2 and 1 months before the end date (once each), then Expired after the expiry date.
CREATE PROCEDURE sp_job_expire_contracts(OUT o_notices INT, OUT o_expired INT)
BEGIN
  DECLARE v_today DATE DEFAULT fn_manila_today();
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  DROP TEMPORARY TABLE IF EXISTS tmp_notice;
  CREATE TEMPORARY TABLE tmp_notice AS
  SELECT k.contract_no, k.client_code, k.expiry_date, m.n AS months, CONCAT('Renewal notice — ', m.n, ' month', IF(m.n > 1, 's', '')) AS label
    FROM contracts k JOIN (SELECT 3 AS n UNION ALL SELECT 2 UNION ALL SELECT 1) m
   WHERE k.status = 'Active' AND k.expiry_date IS NOT NULL AND v_today >= k.expiry_date - INTERVAL m.n MONTH AND v_today <= k.expiry_date
     AND m.n = (SELECT MIN(m2.n) FROM (SELECT 3 AS n UNION ALL SELECT 2 UNION ALL SELECT 1) m2 WHERE v_today >= k.expiry_date - INTERVAL m2.n MONTH)
     AND NOT EXISTS (SELECT 1 FROM contract_events e WHERE e.contract_no = k.contract_no AND e.status_label = CONCAT('Renewal notice — ', m.n, ' month', IF(m.n > 1, 's', '')));
  INSERT INTO contract_events (contract_no, status_label, event_by, note) SELECT contract_no, label, 'system', CONCAT('Expires ', expiry_date) FROM tmp_notice;
  INSERT INTO notifications (user_id, event_type, title, body, link)
  SELECT DISTINCT u.user_id, 'contract.expiring', CONCAT('Contract expiring: ', t.contract_no), CONCAT(c.client_name, ' · expires ', t.expiry_date, ' (', t.months, ' month notice)'), CONCAT('/contracts/', t.contract_no)
    FROM tmp_notice t JOIN clients c ON c.client_code = t.client_code
    JOIN users u ON (u.user_id = c.ae_user_id) OR (u.realm = 'INTERNAL' AND u.status = 'Active' AND EXISTS (SELECT 1 FROM user_roles r WHERE r.user_id = u.user_id AND r.role_code = 'SALES_DIRECTOR'));
  SELECT COUNT(*) INTO o_notices FROM tmp_notice;
  DROP TEMPORARY TABLE tmp_notice;

  DROP TEMPORARY TABLE IF EXISTS tmp_expire;
  CREATE TEMPORARY TABLE tmp_expire AS SELECT contract_no FROM contracts WHERE status = 'Active' AND expiry_date IS NOT NULL AND expiry_date < v_today;
  UPDATE contracts k JOIN tmp_expire x ON x.contract_no = k.contract_no SET k.status = 'Expired', k.row_version = k.row_version + 1;
  INSERT INTO contract_events (contract_no, status_label, event_by, note)
  SELECT k.contract_no, 'Expired', 'system', CONCAT('Expiry date ', k.expiry_date, ' reached') FROM contracts k JOIN tmp_expire x ON x.contract_no = k.contract_no;
  SELECT COUNT(*) INTO o_expired FROM tmp_expire;
  DROP TEMPORARY TABLE tmp_expire;
  -- One audit entry per expired contract (the chain is written row by row).
  BEGIN
    DECLARE v_done INT DEFAULT 0; DECLARE v_no VARCHAR(30);
    DECLARE cur CURSOR FOR SELECT contract_no FROM contract_events WHERE status_label = 'Expired' AND event_by = 'system' AND event_at >= UTC_TIMESTAMP(3) - INTERVAL 1 MINUTE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    OPEN cur;
    a: LOOP
      FETCH cur INTO v_no;
      IF v_done = 1 THEN LEAVE a; END IF;
      CALL sp_audit_write('system', 'SYSTEM', 'contract.expired', 'contract', v_no, NULL, JSON_OBJECT('status', 'Active'), JSON_OBJECT('status', 'Expired'), 'Expiry date reached', 'System job');
      SET v_done = 0;
    END LOOP;
    CLOSE cur;
  END;
  COMMIT;
END$$

-- Housekeeping: used / expired OTP challenges and reset links; read notifications older than 180 days.
CREATE PROCEDURE sp_job_cleanup()
BEGIN
  DELETE FROM auth_otp_challenges WHERE expires_at < UTC_TIMESTAMP(3) - INTERVAL 1 DAY OR consumed_at IS NOT NULL;
  DELETE FROM auth_password_resets WHERE expires_at < UTC_TIMESTAMP(3) - INTERVAL 7 DAY;
  DELETE FROM notifications WHERE is_read = 1 AND created_at < UTC_TIMESTAMP(3) - INTERVAL 180 DAY;
  UPDATE files SET upload_status = 'Deleted' WHERE upload_status = 'Pending' AND created_at < UTC_TIMESTAMP(3) - INTERVAL 1 DAY;  -- abandoned uploads (S3 lifecycle removes the objects)
END$$

-- Worker: claim up to p_batch messages due for sending (SKIP LOCKED lets several workers run safely).
-- Each claim stamps its own token, so several workers can run without sending a message twice.
-- Messages stuck in 'Sending' for 10 minutes (worker crashed) are released back to the queue first.
CREATE PROCEDURE sp_outbox_claim(IN p_batch INT)
BEGIN
  DECLARE v_token CHAR(36) DEFAULT UUID();
  UPDATE message_outbox SET status = 'Queued', claim_token = NULL WHERE status = 'Sending' AND claimed_at < UTC_TIMESTAMP(3) - INTERVAL 10 MINUTE;
  UPDATE message_outbox SET status = 'Sending', attempts = attempts + 1, claim_token = v_token, claimed_at = UTC_TIMESTAMP(3)
   WHERE status = 'Queued' AND next_attempt_at <= UTC_TIMESTAMP(3) ORDER BY message_id LIMIT p_batch;
  SELECT m.message_id AS messageId, m.entity_type AS entityType, m.entity_id AS entityId, m.event_type AS eventType, m.channel, m.audience,
         m.recipient_label AS recipientLabel, m.recipient_name AS recipientName, m.to_address AS toAddress, m.subject, m.body, m.template_data_json AS templateData, m.attempts
    FROM message_outbox m WHERE m.claim_token = v_token ORDER BY m.message_id;
END$$

-- Worker: record the provider result. Failed sends retry with back-off (1, 5, 15, 60 min) up to outbox.max_attempts.
CREATE PROCEDURE sp_outbox_mark(IN p_message_id BIGINT UNSIGNED, IN p_ok TINYINT, IN p_provider_id VARCHAR(200), IN p_error VARCHAR(1000))
BEGIN
  DECLARE v_att INT; DECLARE v_max INT DEFAULT fn_setting_num('outbox.max_attempts', 5);
  SELECT attempts INTO v_att FROM message_outbox WHERE message_id = p_message_id;
  IF p_ok = 1 THEN
    UPDATE message_outbox SET status = 'Sent', sent_at = UTC_TIMESTAMP(3), provider_message_id = p_provider_id, last_error = NULL WHERE message_id = p_message_id;
  ELSEIF v_att >= v_max THEN
    UPDATE message_outbox SET status = 'Failed', last_error = p_error WHERE message_id = p_message_id;
  ELSE
    UPDATE message_outbox SET status = 'Queued', last_error = p_error,
           next_attempt_at = UTC_TIMESTAMP(3) + INTERVAL ELT(LEAST(v_att, 4), 1, 5, 15, 60) MINUTE WHERE message_id = p_message_id;
  END IF;
END$$

DELIMITER ;
