-- =====================================================================================================
-- 06_sp_rescue.sql : Roadside rescue — options, request (BR-01 hold block, funded-wallet rule), list, details
--                    with status timeline and BR-11 charge breakdown, client cancel (only while Requested)
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_rescue_options;
DROP PROCEDURE IF EXISTS sp_rescue_list;
DROP PROCEDURE IF EXISTS sp_rescue_get;
DROP PROCEDURE IF EXISTS sp_rescue_create;
DROP PROCEDURE IF EXISTS sp_rescue_cancel;

DELIMITER $$

-- GET /portal/rescue/options — RS1 {gate, wallet, contacts} · RS2 units on hire · RS3 problem types (setting res.problem_types)
CREATE PROCEDURE sp_rescue_options(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_gate JSON;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SET v_gate = fn_client_gate(v_client, 'RESCUE_REQUEST');
  IF JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.allowed')) = 'true' THEN SET v_gate = fn_rescue_wallet_gate(v_client); END IF;
  SELECT v_gate AS gate, c.status AS clientStatus,
         (SELECT JSON_OBJECT('balance', w.balance, 'minimumBalance', w.minimum_balance, 'state', fn_wallet_state(w.balance, w.minimum_balance)) FROM ewallets w WHERE w.client_code = c.client_code) AS wallet,
         fn_setting_text('res.funded_wallet_rule', 'none') AS fundedWalletRule,
         JSON_OBJECT('name', ae.full_name, 'phone', ae.mobile, 'email', ae.email) AS accountExecutive,
         JSON_OBJECT('phone', fn_setting_text('res.dispatcher_phone', ''), 'email', fn_setting_text('res.dispatcher_email', '')) AS dispatcher
    FROM clients c LEFT JOIN users ae ON ae.user_id = c.ae_user_id WHERE c.client_code = v_client;
  SELECT ch.chassis_no AS chassisNo, ch.chassis_type AS chassisType, ch.status, ch.current_contract_no AS contractNo, ch.current_gate_pass_no AS gatePassNo,
         (SELECT rs.rescue_no FROM rescues rs WHERE rs.chassis_no = ch.chassis_no AND rs.client_code = v_client AND fn_rescue_is_open(rs.status) = 1 LIMIT 1) AS openRescueNo
    FROM chassis ch WHERE ch.current_client_code = v_client AND ch.status IN ('On Hire','Rescue') ORDER BY ch.chassis_no;
  SELECT j.value, j.pricing, j.drives FROM JSON_TABLE(CAST(fn_setting_text('res.problem_types', '[]') AS JSON), '$[*]'
         COLUMNS (value VARCHAR(50) PATH '$.value', pricing VARCHAR(200) PATH '$.pricing', drives VARCHAR(60) PATH '$.drives')) j;
END$$

-- GET /portal/rescue — RS1 rows · RS2 {total}
-- Each row carries what the portal rescue page shows without a second call: crew and dispatch details, BR-11 cost inputs
-- (with the service-fee and VAT rates so the screen shows the same breakdown), status timeline, cost lines, photo names,
-- who was notified, and the hire (Gate Out / Gate In) the incident happened under.
-- PDPA: scene contact, rescue driver and recipient names / addresses are ciphertext, decrypted by the backend for the response.
CREATE PROCEDURE sp_rescue_list(IN p_user_id VARCHAR(100), IN p_q VARCHAR(100), IN p_status VARCHAR(20), IN p_page INT, IN p_page_size INT,
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_size INT DEFAULT LEAST(GREATEST(IFNULL(p_page_size, 8), 1), 100);
  DECLARE v_offset INT DEFAULT (GREATEST(IFNULL(p_page, 1), 1) - 1) * LEAST(GREATEST(IFNULL(p_page_size, 8), 1), 100);
  DECLARE v_q VARCHAR(102) DEFAULT CONCAT('%', IFNULL(TRIM(p_q), ''), '%');
  DECLARE v_svc DECIMAL(18,6) DEFAULT fn_setting_num('res.service_charge_pct', 0.10);
  DECLARE v_vat DECIMAL(18,6) DEFAULT fn_setting_num('fin.vat_pct', 0.12);
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  SELECT r.rescue_no AS rescueNo, r.client_code AS clientCode, r.chassis_no AS chassisNo, ch.chassis_type AS chassisType, r.gate_pass_out_no AS gatePassOutNo,
         r.branch_code AS branchCode, r.status, r.is_urgent AS urgent, r.problem_type AS problemType, r.problem_detail AS problemDetail,
         r.location_text AS locationText, r.lat, r.lng, r.incident, r.load_status AS loadStatus,
         r.scene_contact_name AS sceneContactName, r.scene_contact_phone AS sceneContactPhone,
         r.requested_at AS requestedAt, r.requested_via AS requestedVia, r.blocked_reason AS blockedReason,
         r.crew, r.rescue_vehicle AS rescueVehicle, r.driver_name AS driverName, r.driver_phone AS driverPhone, r.dispatched_at AS dispatchedAt, r.eta,
         r.onsite_assessment AS onsiteAssessment, r.completed_at AS completedAt, r.client_ack_name AS clientAckName, r.acknowledged_at AS acknowledgedAt,
         r.is_chargeable AS chargeable, r.one_way_km AS oneWayKm, r.rate_per_km AS ratePerKm, r.tire_cost AS tireCost, r.parts_cost AS partsCost, r.total,
         r.debit_memo_no AS debitMemoNo, r.ewallet_balance_after AS ewalletBalanceAfter,
         r.cancel_reason AS cancelReason, r.cancelled_at AS cancelledAt,
         fn_rescue_is_open(r.status) AS isOpen, (r.status = 'Requested') AS canCancel, v_svc AS serviceChargePct, v_vat AS vatPct,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', l.log_id, 'status', l.status, 'at', l.status_at, 'by', IFNULL(u.full_name, l.status_by)))
            FROM rescue_status_log l LEFT JOIN users u ON u.user_id = l.status_by WHERE l.rescue_no = r.rescue_no) AS timeline,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('lineNo', cl.line_no, 'kind', cl.kind, 'partCode', cl.part_code, 'description', cl.description, 'qty', cl.qty, 'unitPrice', cl.unit_price))
            FROM rescue_cost_lines cl WHERE cl.rescue_no = r.rescue_no) AS costLines,
         (SELECT JSON_ARRAYAGG(f.original_name) FROM files f
           WHERE f.entity_type = 'rescue' AND f.entity_id = r.rescue_no AND f.upload_status = 'Uploaded' AND f.purpose = 'RESCUE_PHOTO') AS photos,
         (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', m.message_id, 'at', m.queued_at, 'event', m.event_type, 'channel', m.channel, 'audience', m.audience,
                   'recipient', m.recipient_label, 'recipientName', m.recipient_name, 'to', m.to_address, 'subject', m.subject, 'status', m.status))
            FROM message_outbox m WHERE m.entity_type = 'rescue' AND m.entity_id = r.rescue_no) AS notified,
         (SELECT JSON_OBJECT('gatePassNo', go.gate_pass_no, 'branchCode', go.branch_code, 'from', go.actual_event_at, 'to', gi.actual_event_at,
                             'returnGatePassNo', gi.gate_pass_no, 'euNo', go.eu_no)
            FROM gate_passes go LEFT JOIN gate_passes gi ON gi.gate_pass_no = go.paired_gate_pass_no
           WHERE go.gate_pass_no = r.gate_pass_out_no) AS hire
    FROM rescues r LEFT JOIN chassis ch ON ch.chassis_no = r.chassis_no
   WHERE r.client_code = v_client AND (p_status IS NULL OR p_status = '' OR r.status = p_status)
     AND (p_q IS NULL OR p_q = '' OR r.rescue_no LIKE v_q OR r.chassis_no LIKE v_q OR r.location_text LIKE v_q OR r.problem_type LIKE v_q)
   ORDER BY r.requested_at DESC LIMIT v_offset, v_size;
  SELECT COUNT(*) AS total FROM rescues r
   WHERE r.client_code = v_client AND (p_status IS NULL OR p_status = '' OR r.status = p_status)
     AND (p_q IS NULL OR p_q = '' OR r.rescue_no LIKE v_q OR r.chassis_no LIKE v_q OR r.location_text LIKE v_q OR r.problem_type LIKE v_q);
END$$

-- GET /portal/rescue/:no — RS1 header + BR-11 breakdown · RS2 status timeline · RS3 cost lines · RS4 photos · RS5 who was told
CREATE PROCEDURE sp_rescue_get(IN p_user_id VARCHAR(100), IN p_rescue_no VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_svc DECIMAL(18,6) DEFAULT fn_setting_num('res.service_charge_pct', 0.10);
  DECLARE v_vat DECIMAL(18,6) DEFAULT fn_setting_num('fin.vat_pct', 0.12);
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  IF NOT EXISTS (SELECT 1 FROM rescues WHERE rescue_no = p_rescue_no AND client_code = v_client) THEN SET o_err_code = 'NOT_FOUND', o_err_msg = 'Rescue not found.'; LEAVE proc; END IF;
  SELECT r.*, x.travel, x.subtotal, ROUND(x.subtotal * v_svc, 2) AS serviceFee, ROUND(x.subtotal * (1 + v_svc) * v_vat, 2) AS vatAmount,
         ROUND(x.subtotal * (1 + v_svc) * (1 + v_vat), 2) AS computedTotal, v_svc AS serviceChargePct, v_vat AS vatPct,
         IFNULL(r.problemType, 'Not recorded') AS problemTypeLabel, (r.status = 'Requested') AS canCancel
    FROM (SELECT rescue_no AS rescueNo, chassis_no AS chassisNo, gate_pass_out_no AS gatePassOutNo, branch_code AS branchCode, location_text AS locationText, lat, lng,
                 problem_type AS problemType, problem_detail AS problemDetail, incident, load_status AS loadStatus, scene_contact_name AS sceneContactName, scene_contact_phone AS sceneContactPhone,
                 is_urgent AS urgent, status, requested_at AS requestedAt, requested_via AS requestedVia, blocked_reason AS blockedReason, crew, rescue_vehicle AS rescueVehicle,
                 driver_name AS driverName, driver_phone AS driverPhone, dispatched_at AS dispatchedAt, eta, onsite_assessment AS onsiteAssessment, completed_at AS completedAt,
                 client_ack_name AS clientAckName, acknowledged_at AS acknowledgedAt, is_chargeable AS chargeable, one_way_km AS oneWayKm, rate_per_km AS ratePerKm,
                 tire_cost AS tireCost, parts_cost AS partsCost, total, debit_memo_no AS debitMemoNo, ewallet_balance_after AS ewalletBalanceAfter,
                 cancel_reason AS cancelReason, cancelled_at AS cancelledAt
            FROM rescues WHERE rescue_no = p_rescue_no) r
    CROSS JOIN (SELECT ROUND(IFNULL(one_way_km, 0) * 2 * IFNULL(rate_per_km, 0), 2) AS travel,
                       ROUND(IFNULL(one_way_km, 0) * 2 * IFNULL(rate_per_km, 0) + IFNULL(tire_cost, 0) + IFNULL(parts_cost, 0), 2) AS subtotal
                  FROM rescues WHERE rescue_no = p_rescue_no) x;
  SELECT l.status, l.status_at AS at, IFNULL(u.full_name, l.status_by) AS byName FROM rescue_status_log l LEFT JOIN users u ON u.user_id = l.status_by
   WHERE l.rescue_no = p_rescue_no ORDER BY l.log_id;
  SELECT kind, part_code AS partCode, description, qty, unit_price AS unitPrice, ROUND(qty * unit_price, 2) AS amount FROM rescue_cost_lines WHERE rescue_no = p_rescue_no ORDER BY line_no;
  SELECT file_id AS fileId, original_name AS fileName, purpose, scan_status AS scanStatus, created_at AS uploadedAt
    FROM files WHERE entity_type = 'rescue' AND entity_id = p_rescue_no AND upload_status = 'Uploaded' ORDER BY created_at;
  SELECT queued_at AS at, event_type AS event, channel, audience, recipient_label AS recipient, recipient_name AS recipientName, to_address AS `to`, subject, status, sent_at AS sentAt
    FROM message_outbox WHERE entity_type = 'rescue' AND entity_id = p_rescue_no ORDER BY message_id;
END$$

-- POST /portal/rescue — p_photos = JSON array of file_id (RESCUE_PHOTO, up to 5).
-- A client on hold (or without rescue service) is refused — no Blocked record is created (Portal Rescue review, BR-01).
CREATE PROCEDURE sp_rescue_create(IN p_user_id VARCHAR(100), IN p_chassis_no VARCHAR(30), IN p_location_text VARCHAR(500), IN p_lat DECIMAL(9,6), IN p_lng DECIMAL(9,6),
  IN p_problem_type VARCHAR(50), IN p_problem_detail VARCHAR(500), IN p_incident VARCHAR(2000), IN p_load_status VARCHAR(10),
  IN p_scene_contact_name VARCHAR(700), IN p_scene_contact_phone VARCHAR(700), IN p_urgent TINYINT, IN p_photos JSON, IN p_source VARCHAR(200),
  OUT o_rescue_no VARCHAR(20), OUT o_warning VARCHAR(300), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_gate JSON; DECLARE v_status VARCHAR(20); DECLARE v_branch VARCHAR(10); DECLARE v_gp VARCHAR(20); DECLARE v_cname VARCHAR(200); DECLARE v_ae VARCHAR(100);
  DECLARE v_body TEXT; DECLARE v_photo_count INT DEFAULT JSON_LENGTH(IFNULL(p_photos, JSON_ARRAY()));
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL, o_warning = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;

  SET v_gate = fn_client_gate(v_client, 'RESCUE_REQUEST');
  IF JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.allowed')) = 'true' THEN SET v_gate = fn_rescue_wallet_gate(v_client); END IF;
  IF JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.allowed')) <> 'true' THEN
    SET o_err_code = IFNULL(JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.code')), 'CREDIT_GATE_BLOCKED'), o_err_msg = JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.reason')); LEAVE proc;
  END IF;
  SET o_warning = JSON_UNQUOTE(JSON_EXTRACT(v_gate, '$.warning'));
  IF o_warning = 'null' THEN SET o_warning = NULL; END IF;

  SELECT status, branch_code, current_gate_pass_no INTO v_status, v_branch, v_gp FROM chassis WHERE chassis_no = p_chassis_no AND current_client_code = v_client;
  IF v_status IS NULL OR v_status NOT IN ('On Hire','Rescue') THEN
    SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Choose one of your units on hire.', o_err_fields = JSON_OBJECT('chassisNo', 'Not on hire to your account'); LEAVE proc;
  END IF;
  SET o_err_fields = JSON_OBJECT();
  IF p_problem_type IS NULL OR NOT EXISTS (SELECT 1 FROM JSON_TABLE(CAST(fn_setting_text('res.problem_types', '[]') AS JSON), '$[*]' COLUMNS (v VARCHAR(50) PATH '$.value')) j WHERE j.v = p_problem_type) THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.problemType', 'Required');
  END IF;
  IF p_problem_type = 'Other' AND IFNULL(TRIM(p_problem_detail), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.problemDetail', 'Describe the problem'); END IF;
  IF p_load_status IS NULL OR p_load_status NOT IN ('Loaded','Empty') THEN SET o_err_fields = JSON_SET(o_err_fields, '$.loadStatus', 'Required'); END IF;
  IF IFNULL(TRIM(p_location_text), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.locationText', 'Required'); END IF;
  IF IFNULL(TRIM(p_incident), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.incident', 'Required'); END IF;
  -- PDPA: scene contact name / phone arrive encrypted; Node checks "required" and the PH phone format before encrypting.
  IF IFNULL(p_scene_contact_name, '') NOT LIKE 'enc:%' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.sceneContactName', 'Required'); END IF;
  IF IFNULL(p_scene_contact_phone, '') NOT LIKE 'enc:%' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.sceneContactPhone', 'Enter a PH number, e.g. 0917 123 4567'); END IF;
  IF v_photo_count > 5 THEN SET o_err_fields = JSON_SET(o_err_fields, '$.photos', 'Up to 5 photos'); END IF;
  IF v_photo_count > 0 AND v_photo_count <> (SELECT COUNT(*) FROM files f JOIN JSON_TABLE(p_photos, '$[*]' COLUMNS (fid CHAR(36) PATH '$')) j ON j.fid = f.file_id
                                             WHERE f.purpose = 'RESCUE_PHOTO' AND f.uploaded_by = p_user_id AND f.upload_status = 'Uploaded' AND f.entity_id IS NULL) THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.photos', 'Upload the photos again');
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;

  SELECT client_name, ae_user_id INTO v_cname, v_ae FROM clients WHERE client_code = v_client;
  START TRANSACTION;
  CALL sp_next_number('RSC', 'RSC-', 6, o_rescue_no);
  INSERT INTO rescues (rescue_no, client_code, chassis_no, gate_pass_out_no, branch_code, location_text, lat, lng, problem_type, problem_detail, incident, load_status,
                       scene_contact_name, scene_contact_phone, is_urgent, status, requested_at, requested_via, requested_by)
  VALUES (o_rescue_no, v_client, p_chassis_no, v_gp, v_branch, TRIM(p_location_text), p_lat, p_lng, p_problem_type, IF(p_problem_type = 'Other', NULLIF(TRIM(p_problem_detail), ''), NULL),
          TRIM(p_incident), p_load_status, p_scene_contact_name, p_scene_contact_phone, IFNULL(p_urgent, 0), 'Requested', UTC_TIMESTAMP(3), 'Portal', p_user_id);
  INSERT INTO rescue_status_log (rescue_no, status, status_by) VALUES (o_rescue_no, 'Requested', p_user_id);
  UPDATE files f JOIN JSON_TABLE(IFNULL(p_photos, JSON_ARRAY()), '$[*]' COLUMNS (fid CHAR(36) PATH '$')) j ON j.fid = f.file_id
     SET f.entity_type = 'rescue', f.entity_id = o_rescue_no WHERE f.uploaded_by = p_user_id AND f.purpose = 'RESCUE_PHOTO';

  -- Who is told: dispatchers (subject starts with URGENT when urgent), Credit & Collection, the branch, the Account Executive, confirmation to the client.
  SET v_body = CONCAT(IF(p_urgent = 1, 'URGENT · ', ''), p_chassis_no, ' · ', TRIM(p_location_text), ' · ', p_problem_type, ' · ', TRIM(p_incident));
  CALL sp_outbox_queue_roles('rescue', o_rescue_no, 'rescue.requested', JSON_ARRAY('RESCUE_COORDINATOR'), NULL, 'Dispatcher',
       CONCAT(IF(p_urgent = 1, 'URGENT ', ''), 'Rescue ', o_rescue_no, ': ', v_cname), v_body, NULL);
  CALL sp_outbox_queue_roles('rescue', o_rescue_no, 'rescue.requested', JSON_ARRAY('CNC_OFFICER'), NULL, 'Credit & Collection (verifies the request)',
       CONCAT('Rescue ', o_rescue_no, ' to verify: ', v_cname), v_body, NULL);
  CALL sp_outbox_queue_roles('rescue', o_rescue_no, 'rescue.requested', JSON_ARRAY('BRANCH_GENERALIST'), v_branch, CONCAT('Branch ', v_branch),
       CONCAT('Rescue ', o_rescue_no, ': ', v_cname), v_body, NULL);
  CALL sp_outbox_queue('rescue', o_rescue_no, 'rescue.requested', 'Email', 'Delbros', 'Account Executive',
       (SELECT email FROM users WHERE user_id = v_ae), CONCAT('Rescue ', o_rescue_no, ': ', v_cname), v_body, NULL, 0, (SELECT full_name FROM users WHERE user_id = v_ae));
  CALL sp_outbox_queue('rescue', o_rescue_no, 'rescue.requested.portal', 'Email', 'Client', 'Confirmation to you', v_email,
       CONCAT('Rescue ', o_rescue_no, ' received'), CONCAT(p_chassis_no, ' · the dispatcher will call your scene contact to confirm the crew and ETA.'), NULL, 0, v_name);
  CALL sp_notify_roles(JSON_ARRAY('RESCUE_COORDINATOR','CNC_OFFICER'), NULL, 'rescue.requested', CONCAT(IF(p_urgent = 1, 'URGENT ', ''), 'Rescue ', o_rescue_no, ': ', v_cname), v_body, CONCAT('/rescue/', o_rescue_no));
  CALL sp_notify_user(p_user_id, 'rescue.requested.portal', CONCAT('Rescue ', o_rescue_no, ' received'),
       CONCAT(p_chassis_no, IF(p_urgent = 1, ' · urgent', ''), ' · the dispatcher will call your scene contact to confirm the crew and ETA.'), CONCAT('/client/rescue?open=', o_rescue_no));
  CALL sp_audit_write(p_user_id, 'CLIENT', 'rescue.requested', 'rescue', o_rescue_no, v_branch, NULL,
       JSON_OBJECT('chassisNo', p_chassis_no, 'problemType', p_problem_type, 'urgent', p_urgent = 1, 'photos', v_photo_count), NULL, p_source);
  COMMIT;
  CALL sp_rescue_get(p_user_id, o_rescue_no, o_err_code, o_err_msg);
END$$

-- POST /portal/rescue/:no/cancel — only while Requested (before Credit & Collection verifies it).
CREATE PROCEDURE sp_rescue_cancel(IN p_user_id VARCHAR(100), IN p_rescue_no VARCHAR(20), IN p_reason VARCHAR(1000), IN p_source VARCHAR(200),
  OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_status VARCHAR(20); DECLARE v_branch VARCHAR(10); DECLARE v_chassis VARCHAR(30);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'CLIENT_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Client access only.'; LEAVE proc; END IF;
  START TRANSACTION;
  SELECT status, branch_code, chassis_no INTO v_status, v_branch, v_chassis FROM rescues WHERE rescue_no = p_rescue_no AND client_code = v_client FOR UPDATE;
  IF v_status IS NULL THEN ROLLBACK; SET o_err_code = 'NOT_FOUND', o_err_msg = 'Rescue not found.'; LEAVE proc; END IF;
  IF v_status <> 'Requested' THEN ROLLBACK; SET o_err_code = 'INVALID_STATE', o_err_msg = CONCAT(p_rescue_no, ' is already ', LOWER(v_status), ' — call the dispatcher to cancel.'); LEAVE proc; END IF;
  IF IFNULL(TRIM(p_reason), '') = '' THEN ROLLBACK; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'A cancellation reason is required.', o_err_fields = JSON_OBJECT('reason', 'Required'); LEAVE proc; END IF;
  UPDATE rescues SET status = 'Cancelled', cancel_reason = TRIM(p_reason), cancelled_by = p_user_id, cancelled_at = UTC_TIMESTAMP(3), row_version = row_version + 1 WHERE rescue_no = p_rescue_no;
  INSERT INTO rescue_status_log (rescue_no, status, status_by) VALUES (p_rescue_no, 'Cancelled', p_user_id);
  CALL sp_notify_roles(JSON_ARRAY('RESCUE_COORDINATOR','CNC_OFFICER'), NULL, 'rescue.cancelled', CONCAT('Rescue ', p_rescue_no, ' cancelled by the client'),
       CONCAT((SELECT client_name FROM clients WHERE client_code = v_client), ' · ', v_chassis, ' · ', TRIM(p_reason)), CONCAT('/rescue/', p_rescue_no));
  CALL sp_audit_write(p_user_id, 'CLIENT', 'rescue.cancel', 'rescue', p_rescue_no, v_branch, JSON_OBJECT('status', 'Requested'), JSON_OBJECT('status', 'Cancelled'), TRIM(p_reason), p_source);
  COMMIT;
END$$

DELIMITER ;
