-- =====================================================================================================
-- 20_seed_reference.sql : reference data the procedures need to run
--   roles · system settings (with the values still "proposed — awaiting a Delbros decision" flagged) ·
--   equipment types and branches as in the current frontend (REPLACE with migrated DelWater master data)
-- No clients, users, contracts or balances here: those come from the DelWater migration (roadmap layer 9).
-- =====================================================================================================
USE delbros_portal;

-- ── Roles ────────────────────────────────────────────────────────────────────────────────────────────
INSERT INTO roles (role_code, role_name, realm) VALUES
 ('SYS_ADMIN','System Administrator','INTERNAL'), ('BRANCH_GENERALIST','Branch Generalist','INTERNAL'), ('DYM','Depot / Yard Manager','INTERNAL'),
 ('REGIONAL_MANAGER','Regional Manager','INTERNAL'), ('OPS_MANAGER','Operations Manager','INTERNAL'), ('RESCUE_COORDINATOR','Rescue Coordinator / Dispatcher','INTERNAL'),
 ('ACCOUNT_EXECUTIVE','Account Executive','INTERNAL'), ('SALES_DIRECTOR','Sales Director','INTERNAL'), ('CNC_OFFICER','Credit & Collection Officer','INTERNAL'),
 ('CNC_MANAGER','Credit & Collection Manager','INTERNAL'), ('ACCOUNTING','Accounting','INTERNAL'), ('TREASURY','Treasury','INTERNAL'),
 ('FINANCE_MANAGER','Finance Manager','INTERNAL'), ('EXEC_OFFICER','Executive Officer','INTERNAL'), ('APS_OFFICER','APS Officer (Procurement)','INTERNAL'),
 ('APS_MANAGER','APS Manager','INTERNAL'), ('DEPT_HEAD','Department Head','INTERNAL'), ('REGULATORY','Regulatory','INTERNAL'), ('VP','Vice President','INTERNAL'),
 ('CEO','Chief Executive Officer','INTERNAL'), ('CHRO','Chief HR Officer','INTERNAL'), ('PRESIDENT','President','INTERNAL'), ('EXECUTIVE','Executive','INTERNAL'),
 ('WAREHOUSE','Warehouse','INTERNAL'), ('CLIENT','Client portal user','CLIENT_PORTAL'), ('VENDOR','Vendor portal user','VENDOR_PORTAL');

-- ── System settings ──────────────────────────────────────────────────────────────────────────────────
-- is_public = 1: safe to send to a signed-in portal user (sp_ref_all). is_pending_decision = 1: proposed default awaiting Delbros.
INSERT INTO system_settings (setting_key, setting_value, value_type, description, is_public, is_pending_decision) VALUES
 -- Sign-in & security (Q-SEC-03, review group A)
 ('auth.max_failed_logins', '5', 'number', 'Failed sign-ins before the account locks', 0, 1),
 ('auth.lockout_minutes', '30', 'number', 'Lockout duration (minutes)', 0, 1),
 ('auth.password_min_length', '10', 'number', 'Minimum password length (upper, lower, digit also required)', 1, 1),
 ('auth.portal_session_timeout_minutes', '15', 'number', 'Portal idle timeout (minutes)', 1, 1),
 ('auth.portal_second_factor', 'email_otp', 'text', 'Portal second factor: email_otp | off', 0, 1),
 ('auth.otp_minutes', '5', 'number', 'Email sign-in code validity (minutes)', 0, 1),
 ('auth.otp_max_attempts', '5', 'number', 'Wrong codes before the challenge is closed', 0, 1),
 ('auth.otp_resend_seconds', '30', 'number', 'Wait before a new code can be requested (seconds)', 0, 1),
 ('auth.reset_link_minutes', '30', 'number', 'Password reset link validity (minutes)', 0, 1),
 -- Portal
 ('portal.registration_extras', 'tin,documents,consent', 'list', 'Extra fields on Request portal access (Q-PTL-03)', 0, 1),
 ('portal.access_link_days', '7', 'number', 'One-click approval link validity (days)', 0, 1),
 ('portal.default_ae', '', 'text', 'Account Executive assigned to new portal registrations (user_id); per branch: portal.default_ae.<BRANCH>', 0, 1),
 ('portal.client_support_phone', '', 'text', 'Client Support phone (or app-config releaseContacts)', 1, 1),
 ('portal.client_support_email', '', 'text', 'Client Support email', 1, 1),
 ('portal.vendor_support_phone', '', 'text', 'Procurement phone for suppliers', 1, 1),
 ('portal.vendor_support_email', '', 'text', 'Procurement email for suppliers', 1, 1),
 ('portal.dpo_email', '', 'text', 'Data Protection Officer email (privacy notice)', 1, 1),
 -- Company (RPT-016 — blank until Delbros supplies them)
 ('co.name', 'Delbros Leasing Inc.', 'text', 'Issuer name on invoices', 0, 0),
 ('co.address', '', 'text', 'Issuer address on invoices', 0, 1),
 ('co.tin', '', 'text', 'Issuer TIN with branch code', 0, 1),
 ('co.bir_permit', '', 'text', 'BIR permit / ATP details', 0, 1),
 -- Gate / EWA
 ('gat.ewa_validity_hours', '24', 'number', 'EWA validity (BR-06)', 1, 0),
 -- Credit & billing
 ('cnc.hold_threshold_days', '30', 'number', 'Days past due before automatic hold (BR-02)', 0, 0),
 ('fin.credit_term_basis', 'acknowledgment', 'text', 'What starts the credit term: invoice_date | acknowledgment (DBL-CNC-005, provisional)', 1, 1),
 ('fin.weekly_cycle_start', 'Friday', 'text', 'Weekly billing week starts (Friday–Thursday, provisional)', 1, 1),
 ('fin.vat_pct', '0.12', 'number', 'VAT rate', 1, 0),
 ('fin.soa_scope_note', 'This statement lists invoices, debit and credit memos applied to them, and receipts. Debit memos not yet on an invoice and e-wallet deductions are not on this statement.', 'text', 'SOA scope note', 1, 0),
 -- E-wallet
 ('ewl.near_factor', '1.25', 'number', 'Healthy at or above minimum × this factor (EWL-004, proposed)', 1, 1),
 ('ewl.topup_min', '500', 'number', 'Smallest top-up request (₱)', 1, 1),
 ('ewl.topup_max', '5000000', 'number', 'Largest top-up request (₱)', 1, 1),
 ('ewl.topup_max_age_days', '60', 'number', 'Transfer date no older than (days)', 1, 1),
 -- Rescue
 ('res.funded_wallet_rule', 'none', 'text', 'none | wallet_exists | positive | minimum (provisional: none = warn only)', 1, 1),
 ('res.service_charge_pct', '0.10', 'number', 'Rescue service fee (BR-11)', 1, 0),
 ('res.dispatcher_phone', '', 'text', 'Dispatcher hotline shown on the rescue page', 1, 1),
 ('res.dispatcher_email', '', 'text', 'Dispatcher email', 1, 1),
 ('res.problem_types', '[{"value":"Flat / blown tire","pricing":"Travel + tire (from the tire price list)","drives":"Tires"},{"value":"Brake problem","pricing":"Travel + brake parts (drum, lining)","drives":"Parts"},{"value":"Mechanical breakdown","pricing":"Travel + parts used on site","drives":"Parts"},{"value":"Electrical / lights","pricing":"Travel + electrical parts (lamps, wiring)","drives":"Parts"},{"value":"Accident / collision","pricing":"Travel + tires and parts assessed on site","drives":"Tires and parts"},{"value":"Other","pricing":"Travel + tires or parts assessed on site","drives":"Assessed on site"}]', 'list', 'Rescue problem types (proposed — Operations to confirm)', 1, 1),
 -- Contracts
 ('clt.pretermination_cap_days', '30', 'number', 'BR-15 pre-termination fee cap (days, proposed)', 1, 1),
 -- Workflow, files, outbox
 ('wf.escalation_hours', '48', 'number', 'Approval escalation timer', 0, 0),
 ('files.max_mb', '5', 'number', 'Default upload limit (MB)', 1, 0),
 ('outbox.max_attempts', '5', 'number', 'Email send attempts before Failed', 0, 0);

-- ── Equipment types (codes as in the current frontend; names per Q-CLT-01 — confirm) ─────────────────
INSERT INTO equipment_types (equipment_type, type_name, sort_order) VALUES
 ('EQ1','20ft chassis',1), ('EQ2','40ft chassis',2), ('EQ3','40ft flatbed',3), ('EQ4','40ft combo',4),
 ('EQ5','40ft super combo',5), ('EQ6','45ft chassis',6), ('EQ7','Cane cage trailer',7), ('EQ8','20ft flatbed',8);

-- ── Branches (DEMO list from the frontend — replace with the confirmed branch master and managers) ────
INSERT INTO branches (branch_code, branch_name, region, region_group, gate_pass_prefix, billing_entity, is_head_office, issues_gate_passes) VALUES
 ('HO','Head Office','NCR','Luzon','HO','DBL',1,0),
 ('MNL','Manila Yard','NCR','Luzon','MNL','DBL',0,1), ('NVL','Navotas Depot','NCR','Luzon','NVL','DBL',0,1),
 ('CAV','Cavite Depot','South Luzon','Luzon','CAV','DBL',0,1), ('LAG','Laguna Depot','South Luzon','Luzon','LAG','DBL',0,1),
 ('BTG','Batangas Depot','South Luzon','Luzon','BTG','DBL',0,1), ('SUB','Subic Depot','North Luzon','Luzon','SUB','DBL',0,1),
 ('CLK','Clark Depot','North Luzon','Luzon','CLK','DBL',0,1), ('CEB','Cebu Depot','Visayas','Visayas','CEB','DBL',0,1),
 ('CDO','Cagayan de Oro Depot','Mindanao','Mindanao','CDO','NAK',0,1), ('DVO','Davao Depot','Mindanao','Mindanao','DVO','NAK',0,1);
