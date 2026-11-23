-- =====================================================================================================
-- 10_sp_vendor.sql : Vendor portal — my POs (per line ordered / received / outstanding / invoiced / invoiceable),
--                    receiving tranches, invoice tranches, my invoices with status history; invoice upload
--                    (only quantities received and not yet invoiced — excess invoicing refused)
-- =====================================================================================================
USE delbros_portal;

DROP PROCEDURE IF EXISTS sp_vendor_portal_data;
DROP PROCEDURE IF EXISTS sp_vendor_invoice_upload;

DELIMITER $$

-- GET /vendor/portal — RS1 vendor · RS2 POs · RS3 PO line balance · RS4 receiving reports · RS5 my invoices
CREATE PROCEDURE sp_vendor_portal_data(IN p_user_id VARCHAR(100), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000))
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  SET o_err_code = NULL, o_err_msg = NULL;
  CALL sp_ctx_user(p_user_id, 'VENDOR_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Vendor access only.'; LEAVE proc; END IF;

  SELECT vendor_id AS vendorId, vendor_name AS name, tin, address, email, phone, contact_person AS contactPerson, payment_terms AS paymentTerms, status
    FROM vendors WHERE vendor_id = v_vendor;

  SELECT p.po_no AS poNo, p.status, p.terms, p.delivery_date AS deliveryDate, p.entity_code AS entityCode, p.created_at AS createdAt,
         (SELECT IFNULL(SUM(l.qty * l.unit_price), 0) FROM po_lines l WHERE l.po_no = p.po_no) AS total,
         (SELECT IFNULL(SUM(l.qty_received * l.unit_price), 0) FROM po_lines l WHERE l.po_no = p.po_no) AS receivedValue,
         (SELECT IFNULL(SUM(vl.qty * vl.unit_price), 0) FROM vendor_invoice_lines vl JOIN vendor_invoices vi ON vi.vendor_invoice_id = vl.vendor_invoice_id
           WHERE vi.po_no = p.po_no AND vi.vendor_id = v_vendor AND vi.status <> 'Rejected') AS invoicedValue
    FROM purchase_orders p WHERE p.vendor_id = v_vendor AND p.status NOT IN ('Draft','For Approval','Cancelled') ORDER BY p.created_at DESC;

  SELECT l.po_no AS poNo, l.part_code AS partCode, l.description, l.unit_price AS unitPrice, l.qty AS ordered, l.qty_received AS received,
         GREATEST(0, l.qty - l.qty_received) AS outstanding, IFNULL(inv.qty, 0) AS invoiced, GREATEST(0, l.qty_received - IFNULL(inv.qty, 0)) AS invoiceable
    FROM po_lines l JOIN purchase_orders p ON p.po_no = l.po_no
    LEFT JOIN (SELECT vi.po_no, vl.part_code, SUM(vl.qty) AS qty FROM vendor_invoice_lines vl JOIN vendor_invoices vi ON vi.vendor_invoice_id = vl.vendor_invoice_id
                WHERE vi.vendor_id = v_vendor AND vi.status <> 'Rejected' GROUP BY vi.po_no, vl.part_code) inv ON inv.po_no = l.po_no AND inv.part_code = l.part_code
   WHERE p.vendor_id = v_vendor AND p.status NOT IN ('Draft','For Approval','Cancelled') ORDER BY l.po_no, l.part_code;

  SELECT r.po_no AS poNo, r.rr_no AS rrNo, r.received_date AS receivedDate,
         IFNULL((SELECT JSON_ARRAYAGG(JSON_OBJECT('partCode', x.part_code, 'qtyReceived', x.qty_received, 'qtyRejected', x.qty_rejected)) FROM rr_lines x WHERE x.rr_no = r.rr_no), JSON_ARRAY()) AS `lines`
    FROM receiving_reports r JOIN purchase_orders p ON p.po_no = r.po_no WHERE p.vendor_id = v_vendor ORDER BY r.received_date;

  SELECT vi.vendor_invoice_id AS id, vi.po_no AS poNo, vi.invoice_no AS invoiceNo, vi.invoice_date AS invoiceDate, vi.amount, vi.file_id AS fileId,
         (SELECT f.original_name FROM files f WHERE f.file_id = vi.file_id) AS fileName, vi.status,
         vi.submitted_via AS submittedVia, vi.submitted_at AS submittedAt, vi.reject_reason AS rejectReason, vi.resubmit_of AS resubmitOf,
         EXISTS (SELECT 1 FROM vendor_invoices x WHERE x.resubmit_of = vi.vendor_invoice_id) AS resubmitted,
         IFNULL((SELECT JSON_ARRAYAGG(JSON_OBJECT('partCode', l.part_code, 'qty', l.qty, 'unitPrice', l.unit_price)) FROM vendor_invoice_lines l WHERE l.vendor_invoice_id = vi.vendor_invoice_id), JSON_ARRAY()) AS `lines`,
         IFNULL((SELECT JSON_ARRAYAGG(JSON_OBJECT('at', h.status_at, 'status', h.status, 'note', h.note,
                   'byName', IF(h.status_by = p_user_id, 'You', IFNULL((SELECT u.full_name FROM users u WHERE u.user_id = h.status_by AND u.realm = 'INTERNAL'), 'Delbros'))))
            FROM vendor_invoice_history h WHERE h.vendor_invoice_id = vi.vendor_invoice_id), JSON_ARRAY()) AS history
    FROM vendor_invoices vi WHERE vi.vendor_id = v_vendor ORDER BY vi.submitted_at DESC;
END$$

-- POST /vendor/invoices — p_lines = [{"partCode":"TIR-1000R20","qty":3}, …]; p_file_id = uploaded VENDOR_INVOICE file.
CREATE PROCEDURE sp_vendor_invoice_upload(IN p_user_id VARCHAR(100), IN p_po_no VARCHAR(20), IN p_invoice_no VARCHAR(60), IN p_invoice_date DATE,
  IN p_file_id CHAR(36), IN p_lines JSON, IN p_resubmit_of VARCHAR(20), IN p_source VARCHAR(200),
  OUT o_vendor_invoice_id VARCHAR(20), OUT o_err_code VARCHAR(40), OUT o_err_msg VARCHAR(1000), OUT o_err_fields JSON)
proc: BEGIN
  DECLARE v_realm VARCHAR(20); DECLARE v_client VARCHAR(20); DECLARE v_vendor VARCHAR(20); DECLARE v_name VARCHAR(700); DECLARE v_email VARCHAR(700); DECLARE v_ok TINYINT;
  DECLARE v_bad VARCHAR(500); DECLARE v_bad_code VARCHAR(40); DECLARE v_amount DECIMAL(15,2); DECLARE v_vname VARCHAR(200); DECLARE v_count INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; DROP TEMPORARY TABLE IF EXISTS tmp_vi_lines; RESIGNAL; END;
  SET o_err_code = NULL, o_err_msg = NULL, o_err_fields = NULL;
  CALL sp_ctx_user(p_user_id, 'VENDOR_PORTAL', v_realm, v_client, v_vendor, v_name, v_email, v_ok);
  IF v_ok = 0 THEN SET o_err_code = 'FORBIDDEN', o_err_msg = 'Vendor access only.'; LEAVE proc; END IF;
  IF NOT EXISTS (SELECT 1 FROM purchase_orders WHERE po_no = p_po_no AND vendor_id = v_vendor) THEN
    CALL sp_audit_write(p_user_id, 'VENDOR', 'security.vendor_scope_violation', 'po', p_po_no, NULL, NULL, NULL, NULL, p_source);
    SET o_err_code = 'NOT_FOUND', o_err_msg = 'PO not found.'; LEAVE proc;
  END IF;
  SET o_err_fields = JSON_OBJECT();
  IF IFNULL(TRIM(p_invoice_no), '') = '' THEN SET o_err_fields = JSON_SET(o_err_fields, '$.invoiceNo', 'Required');
  ELSEIF EXISTS (SELECT 1 FROM vendor_invoices WHERE vendor_id = v_vendor AND invoice_no_norm = UPPER(TRIM(p_invoice_no)) AND status <> 'Rejected') THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.invoiceNo', 'This invoice number was already submitted'); END IF;
  IF p_invoice_date IS NULL THEN SET o_err_fields = JSON_SET(o_err_fields, '$.invoiceDate', 'Required'); END IF;
  IF NOT EXISTS (SELECT 1 FROM files WHERE file_id = p_file_id AND uploaded_by = p_user_id AND purpose = 'VENDOR_INVOICE' AND upload_status = 'Uploaded' AND entity_id IS NULL) THEN
    SET o_err_fields = JSON_SET(o_err_fields, '$.fileName', 'Attach the invoice');
  END IF;
  IF JSON_LENGTH(o_err_fields) > 0 THEN SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Check the highlighted fields.'; LEAVE proc; END IF;
  SET o_err_fields = NULL;
  IF p_resubmit_of IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vendor_invoices WHERE vendor_invoice_id = p_resubmit_of AND vendor_id = v_vendor AND status = 'Rejected') THEN
    SET o_err_code = 'INVALID_STATE', o_err_msg = 'Only a rejected invoice can be resubmitted.'; LEAVE proc;
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_vi_lines;
  CREATE TEMPORARY TABLE tmp_vi_lines (part_code VARCHAR(30), qty DECIMAL(12,2));
  INSERT INTO tmp_vi_lines SELECT j.p, j.q FROM JSON_TABLE(IFNULL(p_lines, JSON_ARRAY()), '$[*]' COLUMNS (p VARCHAR(30) PATH '$.partCode', q DECIMAL(12,2) PATH '$.qty')) j WHERE j.q > 0;
  SELECT COUNT(*) INTO v_count FROM tmp_vi_lines;
  IF v_count = 0 THEN
    DROP TEMPORARY TABLE tmp_vi_lines; SET o_err_code = 'VALIDATION_FAILED', o_err_msg = 'Enter the quantity you are invoicing on at least one PO line.', o_err_fields = JSON_OBJECT('lines', 'Required'); LEAVE proc;
  END IF;

  START TRANSACTION;
  SELECT 1 INTO v_count FROM purchase_orders WHERE po_no = p_po_no FOR UPDATE;   -- serialise tranches on the same PO
  SELECT CASE WHEN pl.part_code IS NULL THEN 'VALIDATION_FAILED' WHEN t.qty <> FLOOR(t.qty) THEN 'VALIDATION_FAILED' ELSE 'EXCESS_INVOICE' END,
         CASE WHEN pl.part_code IS NULL THEN CONCAT(t.part_code, ' is not on ', p_po_no, '.')
              WHEN t.qty <> FLOOR(t.qty) THEN 'Quantities are whole numbers.'
              ELSE CONCAT(pl.description, ': only ', GREATEST(0, pl.qty_received - IFNULL(inv.qty, 0)), ' received and not yet invoiced (', pl.qty_received, ' received of ', pl.qty,
                          ' ordered, ', IFNULL(inv.qty, 0), ' already invoiced).') END
    INTO v_bad_code, v_bad
    FROM tmp_vi_lines t
    LEFT JOIN po_lines pl ON pl.po_no = p_po_no AND pl.part_code = t.part_code
    LEFT JOIN (SELECT vl.part_code, SUM(vl.qty) AS qty FROM vendor_invoice_lines vl JOIN vendor_invoices vi ON vi.vendor_invoice_id = vl.vendor_invoice_id
                WHERE vi.po_no = p_po_no AND vi.status <> 'Rejected' GROUP BY vl.part_code) inv ON inv.part_code = t.part_code
   WHERE pl.part_code IS NULL OR t.qty <> FLOOR(t.qty) OR t.qty > GREATEST(0, pl.qty_received - IFNULL(inv.qty, 0))
   LIMIT 1;
  IF v_bad IS NOT NULL THEN
    ROLLBACK; DROP TEMPORARY TABLE tmp_vi_lines; SET o_err_code = v_bad_code, o_err_msg = v_bad, o_err_fields = JSON_OBJECT('lines', v_bad); LEAVE proc;
  END IF;

  CALL sp_next_number('VI', 'VI-', 6, o_vendor_invoice_id);
  SELECT ROUND(SUM(t.qty * pl.unit_price), 2) INTO v_amount FROM tmp_vi_lines t JOIN po_lines pl ON pl.po_no = p_po_no AND pl.part_code = t.part_code;
  INSERT INTO vendor_invoices (vendor_invoice_id, vendor_id, po_no, invoice_no, invoice_date, amount, file_id, status, submitted_via, resubmit_of)
  VALUES (o_vendor_invoice_id, v_vendor, p_po_no, TRIM(p_invoice_no), p_invoice_date, v_amount, p_file_id, 'Submitted', 'Portal', p_resubmit_of);
  INSERT INTO vendor_invoice_lines (vendor_invoice_id, part_code, qty, unit_price)
  SELECT o_vendor_invoice_id, t.part_code, t.qty, pl.unit_price FROM tmp_vi_lines t JOIN po_lines pl ON pl.po_no = p_po_no AND pl.part_code = t.part_code;
  DROP TEMPORARY TABLE tmp_vi_lines;
  INSERT INTO vendor_invoice_history (vendor_invoice_id, status, status_by, note)
  VALUES (o_vendor_invoice_id, 'Submitted', p_user_id, IF(p_resubmit_of IS NULL, NULL, CONCAT('Resubmission of ', (SELECT invoice_no FROM vendor_invoices WHERE vendor_invoice_id = p_resubmit_of))));
  UPDATE files SET entity_type = 'vendor_invoice', entity_id = o_vendor_invoice_id WHERE file_id = p_file_id;
  SELECT vendor_name INTO v_vname FROM vendors WHERE vendor_id = v_vendor;
  CALL sp_notify_roles(JSON_ARRAY('APS_OFFICER','ACCOUNTING'), NULL, 'vendor.invoice_submitted', CONCAT('Supplier invoice ', TRIM(p_invoice_no), ': ', v_vname),
       CONCAT(p_po_no, ' · ₱', FORMAT(v_amount, 2)), '/procurement/payables');
  CALL sp_audit_write(p_user_id, 'VENDOR', 'vendor_invoice.submitted', 'vendor_invoice', o_vendor_invoice_id, NULL, NULL,
       JSON_OBJECT('poNo', p_po_no, 'invoiceNo', TRIM(p_invoice_no), 'amount', v_amount, 'lines', p_lines, 'resubmitOf', p_resubmit_of), NULL, p_source);
  COMMIT;
  SELECT vi.vendor_invoice_id AS id, vi.vendor_id AS vendorId, vi.po_no AS poNo, vi.invoice_no AS invoiceNo, vi.invoice_date AS invoiceDate, vi.amount, vi.file_id AS fileId,
         (SELECT f.original_name FROM files f WHERE f.file_id = vi.file_id) AS fileName, vi.status, vi.submitted_via AS submittedVia, vi.submitted_at AS submittedAt, vi.resubmit_of AS resubmitOf
    FROM vendor_invoices vi WHERE vi.vendor_invoice_id = o_vendor_invoice_id;
END$$

DELIMITER ;
