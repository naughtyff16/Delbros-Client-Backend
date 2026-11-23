#!/usr/bin/env node
// =====================================================================================================
// Sample (dummy) data for DEVELOPMENT / UAT — NEVER run against production.
//
//   node database/sample/generate-sample-data.js        (or: npm run sample-data)
//   → writes database/30_sample_data.sql, then checks it with check-columns.js
//
// Why a generator: personal-data columns hold AES-256-GCM ciphertext and *_hash blind indexes made with the
// keys in App/.env (PII_ENCRYPTION_KEY, PII_HASH_KEY). The SQL is therefore TIED TO THOSE KEYS — regenerate it
// whenever the keys change, or the portal shows "[unreadable]" and sample sign-ins fail.
//
// Accounts mirror the frontend demo box (src/pages/public.tsx DEMO_ACCOUNTS), all with password Demo@2026.
// All dates are SQL expressions relative to the day the script is RUN (Manila calendar), so the data stays fresh.
// =====================================================================================================
const fs = require('fs');
const path = require('path');
const crypto = require('../../App/controllers/cryptoController');
const bcrypt = require('bcryptjs');

const OUT = path.join(__dirname, '..', '30_sample_data.sql');
// Placeholder files for the sample rows (real PDF / JPG content) → copy database/sample/files/* into FILE_DIR on the server.
const FILES_OUT = path.join(__dirname, 'files');
const TINY_JPG = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=', 'base64');
function samplePdf(title) {
  const text = String(title).replace(/[()\\]/g, ' ');
  const objs = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>', null,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  const stream = `BT /F1 16 Tf 60 780 Td (Delbros portal - SAMPLE FILE) Tj 0 -28 Td /F1 12 Tf (${text}) Tj ET`;
  objs[3] = `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`;
  let pdf = '%PDF-1.4\n';
  const offs = [];
  objs.forEach((o, i) => { offs.push(pdf.length); pdf += `${i + 1} 0 obj\n${o}\nendobj\n`; });
  const x = pdf.length;
  pdf += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offs.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')}`;
  pdf += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;
  return Buffer.from(pdf, 'latin1');
}
const DEMO_PASSWORD = 'Demo@2026';

// ── SQL value helpers ────────────────────────────────────────────────────────────────────────────
const raw = (sql) => ({ raw: sql });
const lit = (v) => {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'object' && 'raw' in v) return v.raw;
  if (typeof v === 'number') { if (!Number.isFinite(v)) throw new Error(`bad number ${v}`); return String(v); }
  if (typeof v === 'boolean') return v ? '1' : '0';
  return `'${String(v).replace(/\\/g, '\\\\').replace(/'/g, "''")}'`;
};
/** Manila calendar date n days from today. */
const d = (n) => raw(`DATE_ADD(fn_manila_today(), INTERVAL ${n} DAY)`);
/** UTC DATETIME for Manila wall time hh:mm on the day n days from today. */
const t = (n, hm = '09:00') => raw(`(TIMESTAMP(DATE_ADD(fn_manila_today(), INTERVAL ${n} DAY), '${hm}:00') - INTERVAL 8 HOUR)`);
/** UTC now ± minutes. */
const ago = (min) => raw(`(UTC_TIMESTAMP(3) - INTERVAL ${min} MINUTE)`);
const ahead = (min) => raw(`(UTC_TIMESTAMP(3) + INTERVAL ${min} MINUTE)`);
const enc = (v) => crypto.encrypt(v);
const json = (v) => JSON.stringify(v);
const r2 = (n) => Math.round(n * 100) / 100;
const uuid = (n) => `5a5a0000-0000-4000-8000-${String(n).padStart(12, '0')}`;

const out = [];
const counts = {};
function ins(table, rows) {
  if (!rows.length) return;
  const cols = Object.keys(rows[0]);
  for (const r of rows) {
    const k = Object.keys(r);
    if (k.length !== cols.length || k.some((c, i) => c !== cols[i])) throw new Error(`${table}: rows must have the same columns in the same order (${k.join(',')})`);
  }
  const q = (c) => (c === 'last_value' ? '`last_value`' : c);
  out.push(`INSERT INTO ${table} (${cols.map(q).join(', ')}) VALUES\n${rows.map((r) => ` (${cols.map((c) => lit(r[c])).join(', ')})`).join(',\n')};`);
  counts[table] = (counts[table] || 0) + rows.length;
}
const section = (title) => out.push(`\n-- ── ${title} ${'─'.repeat(Math.max(0, 96 - title.length))}`);

// =====================================================================================================
async function main() {
  const demoHash = await bcrypt.hash(DEMO_PASSWORD, 10);
  const staffHash = await bcrypt.hash(crypto.randomToken(16), 10); // staff never sign in to the portal

  // ── Master data not in 20_seed_reference.sql ────────────────────────────────────────────────────
  section('Settings for the sample environment (support contacts, default Account Executive)');
  const setting = (k, v) => out.push(`UPDATE system_settings SET setting_value = ${lit(v)}, updated_by = 'sample-data' WHERE setting_key = ${lit(k)};`);
  setting('portal.default_ae', 'AE.JREYES');
  setting('portal.client_support_phone', '(02) 8123 4567');
  setting('portal.client_support_email', 'clientsupport@delbros.example');
  setting('portal.vendor_support_phone', '(02) 8123 4570');
  setting('portal.vendor_support_email', 'procurement@delbros.example');
  setting('portal.dpo_email', 'dpo@delbros.example');
  setting('res.dispatcher_phone', '0917 800 1234');
  setting('res.dispatcher_email', 'rescue@delbros.example');
  out.push(`INSERT INTO system_settings (setting_key, setting_value, value_type, description, is_public, is_pending_decision) VALUES
 ('portal.default_ae.CDO', 'AE.MSANTOS', 'text', 'Account Executive for new portal registrations at CDO (sample)', 0, 1),
 ('portal.default_ae.DVO', 'AE.MSANTOS', 'text', 'Account Executive for new portal registrations at DVO (sample)', 0, 1)
 ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value);`);
  counts.system_settings = 2;

  section('Rate cards (BR-18, current list prices per equipment type and contract type)');
  const base = { EQ1: 850, EQ2: 1100, EQ3: 1150, EQ4: 1250, EQ5: 1400, EQ6: 1300, EQ7: 1500, EQ8: 800 };
  const rc = [];
  for (const [eq, rate] of Object.entries(base)) {
    rc.push({ equipment_type: eq, contract_type: 'LTL', contract_class: 'A', daily_rate: r2(rate * 1.05), indemnity: rate * 400, valid_from: d(-730), valid_to: d(-181), reason: '2025 rate card', created_by: 'SYSTEM' });
    rc.push({ equipment_type: eq, contract_type: 'LTL', contract_class: 'A', daily_rate: rate, indemnity: rate * 400, valid_from: d(-180), valid_to: null, reason: 'Current rate card', created_by: 'SYSTEM' });
    rc.push({ equipment_type: eq, contract_type: 'SPL', contract_class: 'Z', daily_rate: r2(rate * 1.2), indemnity: rate * 400, valid_from: d(-180), valid_to: null, reason: 'Current rate card', created_by: 'SYSTEM' });
    rc.push({ equipment_type: eq, contract_type: 'QLP', contract_class: 'Q', daily_rate: r2(rate * 0.9), indemnity: rate * 400, valid_from: d(-180), valid_to: null, reason: 'Current rate card', created_by: 'SYSTEM' });
  }
  ins('rate_cards', rc);

  section('Parts (vendor POs and rescue cost lines)');
  ins('parts', [
    { part_code: 'TIRE-1100R20', description: 'Tire 11.00R20 (radial)', uom: 'pc', category: 'Tires', standard_cost: 14500, rescue_price: 16800, is_active: 1 },
    { part_code: 'TIRE-1000R20', description: 'Tire 10.00R20 (bias)', uom: 'pc', category: 'Tires', standard_cost: 11800, rescue_price: 13500, is_active: 1 },
    { part_code: 'BRK-LINING', description: 'Brake lining set', uom: 'set', category: 'Brakes', standard_cost: 2400, rescue_price: 2900, is_active: 1 },
    { part_code: 'BRK-DRUM', description: 'Brake drum', uom: 'pc', category: 'Brakes', standard_cost: 6200, rescue_price: 7100, is_active: 1 },
    { part_code: 'LAMP-LED', description: 'LED tail lamp assembly', uom: 'pc', category: 'Electrical', standard_cost: 950, rescue_price: 1200, is_active: 1 },
    { part_code: 'MUDFLAP', description: 'Mud flap with bracket', uom: 'pc', category: 'Body', standard_cost: 650, rescue_price: 800, is_active: 1 },
  ]);

  section('Notification rules (who is told — used by the staff app; listed for completeness)');
  ins('notification_rules', [
    { rule_id: 'N01', event_type: 'ewa.created', description: 'EWA created in the portal', recipient_roles_json: json(['BRANCH_GENERALIST']), include_client: 1, include_ae: 1, channels_json: json(['Email', 'In-App']), mode: 'One-time', repeat_minutes: null, escalation_hours: null, escalate_to_json: null, template_subject: 'EWA {{euNo}} created', template_body: null, is_active: 1 },
    { rule_id: 'N05', event_type: 'rescue.requested', description: 'Rescue requested', recipient_roles_json: json(['RESCUE_COORDINATOR']), include_client: 1, include_ae: 1, channels_json: json(['Email', 'In-App']), mode: 'Repeat until ack', repeat_minutes: 15, escalation_hours: 1, escalate_to_json: json(['OPS_MANAGER']), template_subject: 'Rescue {{rescueNo}} requested', template_body: null, is_active: 1 },
    { rule_id: 'N08', event_type: 'topup.submitted', description: 'Top-up submitted', recipient_roles_json: json(['TREASURY']), include_client: 1, include_ae: 0, channels_json: json(['Email', 'In-App']), mode: 'One-time', repeat_minutes: null, escalation_hours: 24, escalate_to_json: json(['FINANCE_MANAGER']), template_subject: 'Top-up {{topupId}} to confirm', template_body: null, is_active: 1 },
    { rule_id: 'N12', event_type: 'client.return_request', description: 'Return requested', recipient_roles_json: json(['BRANCH_GENERALIST']), include_client: 1, include_ae: 1, channels_json: json(['Email', 'In-App']), mode: 'One-time', repeat_minutes: null, escalation_hours: null, escalate_to_json: null, template_subject: 'Return {{requestNo}} requested', template_body: null, is_active: 1 },
  ]);

  // ── Staff ───────────────────────────────────────────────────────────────────────────────────────
  section('Delbros staff (INTERNAL users — referenced as Account Executive, Credit & Collection, branch staff)');
  const staff = [
    ['AE.JREYES', 'Juan Reyes', 'Account Executive', 'juan.reyes@delbros.example', '0917 555 0101', 'MNL', ['ACCOUNT_EXECUTIVE']],
    ['AE.MSANTOS', 'Maria Santos', 'Account Executive — Mindanao', 'maria.santos@delbros.example', '0917 555 0102', 'CDO', ['ACCOUNT_EXECUTIVE']],
    ['CNC.LCRUZ', 'Liza Cruz', 'Credit & Collection Officer', 'liza.cruz@delbros.example', '0917 555 0103', 'MNL', ['CNC_OFFICER']],
    ['CNC.MGR.RBAUTISTA', 'Ramon Bautista', 'Credit & Collection Manager', 'ramon.bautista@delbros.example', '0917 555 0104', 'HO', ['CNC_MANAGER']],
    ['BG.MNL.PDIAZ', 'Paolo Diaz', 'Branch Generalist — Manila', 'paolo.diaz@delbros.example', '0917 555 0105', 'MNL', ['BRANCH_GENERALIST']],
    ['BG.CAV.RGARCIA', 'Rhea Garcia', 'Branch Generalist — Cavite', 'rhea.garcia@delbros.example', '0917 555 0106', 'CAV', ['BRANCH_GENERALIST']],
    ['BG.LAG.NVILLAR', 'Noel Villar', 'Branch Generalist — Laguna', 'noel.villar@delbros.example', '0917 555 0107', 'LAG', ['BRANCH_GENERALIST']],
    ['BG.NVL.SPEREZ', 'Sheila Perez', 'Branch Generalist — Navotas', 'sheila.perez@delbros.example', '0917 555 0108', 'NVL', ['BRANCH_GENERALIST']],
    ['BG.CDO.ALIM', 'Abdul Lim', 'Branch Generalist — Cagayan de Oro', 'abdul.lim@delbros.example', '0917 555 0109', 'CDO', ['BRANCH_GENERALIST']],
    ['RSC.DMORALES', 'Dennis Morales', 'Rescue Coordinator', 'dennis.morales@delbros.example', '0917 555 0110', 'MNL', ['RESCUE_COORDINATOR']],
    ['TRS.ELOPEZ', 'Elena Lopez', 'Treasury', 'elena.lopez@delbros.example', '0917 555 0111', 'HO', ['TREASURY']],
    ['ACC.BVILLA', 'Bea Villa', 'Accounting', 'bea.villa@delbros.example', '0917 555 0112', 'HO', ['ACCOUNTING']],
    ['FIN.GTAN', 'Gloria Tan', 'Finance Manager', 'gloria.tan@delbros.example', '0917 555 0113', 'HO', ['FINANCE_MANAGER']],
    ['APS.KTAN', 'Kevin Tan', 'APS Officer (Procurement)', 'kevin.tan@delbros.example', '0917 555 0114', 'HO', ['APS_OFFICER']],
    ['SD.FAQUINO', 'Fe Aquino', 'Sales Director', 'fe.aquino@delbros.example', '0917 555 0115', 'HO', ['SALES_DIRECTOR']],
    ['OPS.HNAVARRO', 'Hector Navarro', 'Operations Manager', 'hector.navarro@delbros.example', '0917 555 0116', 'HO', ['OPS_MANAGER']],
  ];
  const staffEmail = Object.fromEntries(staff.map((s) => [s[0], s[3]]));
  const staffName = Object.fromEntries(staff.map((s) => [s[0], s[1]]));
  ins('users', staff.map(([id, name, desig, email, mobile, br]) => ({
    user_id: id, realm: 'INTERNAL', full_name: enc(name), designation: desig, email: enc(email), email_hash: crypto.blindIndex('email', email), mobile: enc(mobile),
    status: 'Active', branch_code: br, all_branches: br === 'HO' ? 1 : 0, client_code: null, vendor_id: null, password_hash: staffHash,
    must_change_password: 0, password_changed_at: t(-200), failed_logins: 0, locked_until: null, last_login_at: ago(600),
  })));
  ins('user_roles', staff.flatMap(([id, , , , , , roles]) => roles.map((r) => ({ user_id: id, role_code: r }))));
  ins('user_branch_access', [
    { user_id: 'AE.JREYES', branch_code: 'MNL' }, { user_id: 'AE.JREYES', branch_code: 'CAV' }, { user_id: 'AE.JREYES', branch_code: 'LAG' }, { user_id: 'AE.JREYES', branch_code: 'NVL' },
    { user_id: 'AE.MSANTOS', branch_code: 'CDO' }, { user_id: 'AE.MSANTOS', branch_code: 'DVO' }, { user_id: 'AE.MSANTOS', branch_code: 'CEB' },
  ]);

  // ── Clients ─────────────────────────────────────────────────────────────────────────────────────
  section('Clients (one per demo-box state)');
  const client = (code, name, o) => ({
    client_code: code, client_name: name, billing_name: o.billing || `${name}`, qb_name: name.toUpperCase(), tin: o.tin ? enc(o.tin) : null, tin_hash: o.tin ? crypto.blindIndex('tin', o.tin) : null,
    vat_status: 'VAT-registered', address1: o.address, address2: null, city: o.city, zip_code: o.zip, country: 'PHILIPPINES',
    phone: enc(o.phone), email: enc(o.email), ebilling_email: o.ebilling ? enc(o.ebilling) : null, billing_cycle: 'Weekly', ae_user_id: o.ae || 'AE.JREYES', branch_code: o.branch,
    status: o.status || 'Active', allow_lt: 1, allow_st: 1, allow_online: o.online ?? 1, allow_special: 0, allow_rescue: o.rescue ?? 1, is_legal: 0, is_collection_agency: 0,
    credit_limit: o.limit ?? 500000, registration_source: o.source || 'Internal', notes: o.notes || null,
  });
  ins('clients', [
    client('C-00123', 'ABC Logistics Corp.', { billing: 'ABC Logistics Corporation', tin: '123-456-789-000', address: '1200 Road 10, Port Area', city: 'Manila', zip: '1018', phone: '(02) 8527 1100', email: 'accounts@abclogistics.ph', ebilling: 'billing@abclogistics.ph', branch: 'MNL', limit: 1500000, notes: 'Sample: rich data on every screen' }),
    client('C-00124', 'Pacific Movers Inc.', { tin: '234-567-890-000', address: '45 Aguinaldo Highway', city: 'Bacoor, Cavite', zip: '4102', phone: '(046) 417 2200', email: 'accounts@pacificmovers.ph', branch: 'CAV', status: 'Hold', notes: 'Sample: automatic credit hold (BR-02)' }),
    client('C-00125', 'Southern Haulers Trading', { tin: '345-678-901-000', address: 'Km 5 National Highway, Bulua', city: 'Cagayan de Oro', zip: '9000', phone: '(088) 856 3300', email: 'accounts@southernhaulers.ph', branch: 'CDO', ae: 'AE.MSANTOS', online: 0, notes: 'Sample: Mindanao (Nakamura billing), Allow Online = No' }),
    client('C-00126', 'Islandlink Cargo Services', { tin: '456-789-012-000', address: '88 Mabini St.', city: 'Batangas City', zip: '4200', phone: '0918 222 3344', email: 'tess@islandlink.ph', branch: 'BTG', status: 'Draft', online: 0, rescue: 0, limit: null, source: 'Portal', notes: 'Sample: portal access request pending' }),
    client('C-00127', 'Northstar Trucking Co.', { tin: '567-890-123-000', address: '12 MacArthur Highway', city: 'Angeles, Pampanga', zip: '2009', phone: '(045) 322 4455', email: 'rico@northstar.ph', branch: 'CLK', status: 'Draft', online: 0, rescue: 0, limit: null, notes: 'Sample: accreditation pending (not accredited)' }),
    client('C-00128', 'Visayas Freight Lines', { tin: '678-901-234-000', address: 'Pier 4, North Reclamation Area', city: 'Cebu City', zip: '6000', phone: '(032) 412 5566', email: 'dispatch@visayasfreight.ph', branch: 'CEB', ae: 'AE.MSANTOS', notes: 'Sample: portal user locked after failed sign-ins' }),
    client('C-00129', 'Bayside Haulage Corp.', { tin: '789-012-345-000', address: '3 Coastal Road', city: 'Parañaque', zip: '1700', phone: '(02) 8851 6677', email: 'finance@baysidehaulage.ph', branch: 'MNL', notes: 'Sample: contract ended, cash bond refundable' }),
    client('C-00130', 'Metro Container Express', { tin: '890-123-456-000', address: '21 C-3 Road', city: 'Navotas', zip: '1485', phone: '(02) 8281 7788', email: 'ops@metrocontainer.ph', branch: 'NVL', notes: 'Sample: e-wallet below minimum' }),
  ]);
  ins('client_contacts', [
    { contact_id: 1, client_code: 'C-00123', first_name: enc('Ana'), last_name: enc('Reyes'), phone: enc('0917 123 4567'), email: enc('client@abclogistics.ph'), email_hash: crypto.blindIndex('email', 'client@abclogistics.ph'), is_primary: 1, is_signatory: 0, is_active: 1 },
    { contact_id: 2, client_code: 'C-00123', first_name: enc('Roberto'), last_name: enc('Lim'), phone: enc('0917 765 4321'), email: enc('roberto.lim@abclogistics.ph'), email_hash: crypto.blindIndex('email', 'roberto.lim@abclogistics.ph'), is_primary: 0, is_signatory: 1, is_active: 1 },
    { contact_id: 3, client_code: 'C-00124', first_name: enc('Carlo'), last_name: enc('Mendoza'), phone: enc('0918 111 2233'), email: enc('client@pacificmovers.ph'), email_hash: crypto.blindIndex('email', 'client@pacificmovers.ph'), is_primary: 1, is_signatory: 1, is_active: 1 },
    { contact_id: 4, client_code: 'C-00125', first_name: enc('Dina'), last_name: enc('Ali'), phone: enc('0917 444 5566'), email: enc('ops@southernhaulers.ph'), email_hash: crypto.blindIndex('email', 'ops@southernhaulers.ph'), is_primary: 1, is_signatory: 1, is_active: 1 },
    { contact_id: 5, client_code: 'C-00126', first_name: enc('Tess'), last_name: enc('Ramirez'), phone: enc('0918 222 3344'), email: enc('tess@islandlink.ph'), email_hash: crypto.blindIndex('email', 'tess@islandlink.ph'), is_primary: 1, is_signatory: 0, is_active: 1 },
    { contact_id: 6, client_code: 'C-00127', first_name: enc('Rico'), last_name: enc('Valdez'), phone: enc('0919 333 4455'), email: enc('rico@northstar.ph'), email_hash: crypto.blindIndex('email', 'rico@northstar.ph'), is_primary: 1, is_signatory: 1, is_active: 1 },
    { contact_id: 7, client_code: 'C-00128', first_name: enc('Victor'), last_name: enc('Gomez'), phone: enc('0917 888 9900'), email: enc('dispatch@visayasfreight.ph'), email_hash: crypto.blindIndex('email', 'dispatch@visayasfreight.ph'), is_primary: 1, is_signatory: 1, is_active: 1 },
    { contact_id: 8, client_code: 'C-00129', first_name: enc('Bianca'), last_name: enc('Torres'), phone: enc('0917 222 1100'), email: enc('finance@baysidehaulage.ph'), email_hash: crypto.blindIndex('email', 'finance@baysidehaulage.ph'), is_primary: 1, is_signatory: 1, is_active: 1 },
    { contact_id: 9, client_code: 'C-00130', first_name: enc('Mark'), last_name: enc('Sison'), phone: enc('0918 555 0011'), email: enc('ops@metrocontainer.ph'), email_hash: crypto.blindIndex('email', 'ops@metrocontainer.ph'), is_primary: 1, is_signatory: 1, is_active: 1 },
  ]);
  ins('client_branch_access', [
    ['C-00123', 'MNL'], ['C-00123', 'CAV'], ['C-00123', 'LAG'], ['C-00123', 'NVL'],
    ['C-00124', 'CAV'], ['C-00124', 'MNL'], ['C-00125', 'CDO'], ['C-00125', 'DVO'], ['C-00128', 'CEB'], ['C-00129', 'MNL'], ['C-00130', 'NVL'], ['C-00130', 'MNL'],
  ].map(([c, b]) => ({ client_code: c, branch_code: b, added_at: t(-360), added_reference: null })));
  ins('accreditations', [
    { accreditation_id: 'ACC-000101', client_code: 'C-00127', status: 'Pending C&C', workflow_id: null, tin: enc('567-890-123-000'), tin_hash: crypto.blindIndex('tin', '567-890-123-000'), submitted_at: t(-6) },
    { accreditation_id: 'ACC-000090', client_code: 'C-00123', status: 'Approved', workflow_id: null, tin: enc('123-456-789-000'), tin_hash: crypto.blindIndex('tin', '123-456-789-000'), submitted_at: t(-420) },
  ]);
  ins('hold_events', [
    { client_code: 'C-00124', event_type: 'Auto Hold', event_at: t(-12, '01:00'), event_by: 'system', outstanding: 134400, days_overdue: 38, invoice_no: 'INV-CAV-00000501', reason: 'Automatic hold: invoice more than 30 days past due (BR-02)', workflow_id: null },
  ]);

  // ── Vendors (before vendor portal users) ────────────────────────────────────────────────────────
  section('Vendors (suppliers)');
  const vendor = (id, name, status, o) => ({ vendor_id: id, vendor_name: name, tin: enc(o.tin), tin_hash: crypto.blindIndex('tin', o.tin), address: o.address, email: enc(o.email), email_hash: crypto.blindIndex('email', o.email),
    phone: enc(o.phone), contact_person: enc(o.contact), payment_terms: o.terms || '30 days', vat_status: 'VAT-registered', status, status_reason: o.reason || null, portal_access: o.portal ?? 1 });
  ins('vendors', [
    vendor('V-001', 'Tire Pro Supply Inc.', 'Active', { tin: '901-234-567-000', address: '77 EDSA, Caloocan City', email: 'vendor@tirepro.ph', phone: '(02) 8361 2200', contact: 'Eric Lim' }),
    vendor('V-002', 'Luzon Brake Parts Trading', 'Pending', { tin: '912-345-678-000', address: '5 Rizal Ave., San Fernando, Pampanga', email: 'sales@luzonbrake.ph', phone: '(045) 961 3300', contact: 'Gina Cruz', terms: 'To be agreed', reason: 'Accreditation documents under review' }),
    vendor('V-003', 'Metro Paint Center', 'Inactive', { tin: '923-456-789-000', address: '19 Shaw Blvd., Mandaluyong', email: 'orders@metropaint.ph', phone: '(02) 8631 4400', contact: 'Paul Uy', reason: 'No transactions since 2024' }),
  ]);

  // ── Portal users ────────────────────────────────────────────────────────────────────────────────
  section(`Portal users — demo password for every account: ${DEMO_PASSWORD}`);
  const pu = (id, realm, email, name, mobile, o = {}) => ({
    user_id: id, realm, full_name: enc(name), designation: o.desig || null, email: enc(email), email_hash: crypto.blindIndex('email', email), mobile: enc(mobile),
    status: o.status || 'Active', branch_code: null, all_branches: 0, client_code: realm === 'CLIENT_PORTAL' ? o.client : null, vendor_id: realm === 'VENDOR_PORTAL' ? o.vendor : null,
    password_hash: demoHash, must_change_password: 0, password_changed_at: t(-90), failed_logins: o.failed || 0, locked_until: o.locked || null, last_login_at: o.last === undefined ? ago(1500) : o.last,
  });
  const PORTAL = [
    pu('U-000001', 'CLIENT_PORTAL', 'client@abclogistics.ph', 'Ana Reyes', '0917 123 4567', { client: 'C-00123', desig: 'Logistics Manager' }),
    pu('U-000002', 'CLIENT_PORTAL', 'j.cruz@abclogistics.ph', 'Jose Cruz', '0917 234 5678', { client: 'C-00123', status: 'Inactive', desig: 'Dispatcher (left the company)', last: t(-120) }),
    pu('U-000003', 'CLIENT_PORTAL', 'client@pacificmovers.ph', 'Carlo Mendoza', '0918 111 2233', { client: 'C-00124', desig: 'Operations Head' }),
    pu('U-000004', 'CLIENT_PORTAL', 'ops@southernhaulers.ph', 'Dina Ali', '0917 444 5566', { client: 'C-00125', desig: 'Operations' }),
    pu('U-000005', 'CLIENT_PORTAL', 'rico@northstar.ph', 'Rico Valdez', '0919 333 4455', { client: 'C-00127', desig: 'Owner', last: null }),
    pu('U-000006', 'CLIENT_PORTAL', 'tess@islandlink.ph', 'Tess Ramirez', '0918 222 3344', { client: 'C-00126', status: 'Inactive', desig: 'General Manager', last: null }),
    pu('U-000007', 'CLIENT_PORTAL', 'dispatch@visayasfreight.ph', 'Victor Gomez', '0917 888 9900', { client: 'C-00128', failed: 5, locked: ahead(25), desig: 'Dispatcher' }),
    pu('U-000008', 'CLIENT_PORTAL', 'finance@baysidehaulage.ph', 'Bianca Torres', '0917 222 1100', { client: 'C-00129', desig: 'Finance Officer' }),
    pu('U-000009', 'CLIENT_PORTAL', 'ops@metrocontainer.ph', 'Mark Sison', '0918 555 0011', { client: 'C-00130', desig: 'Operations' }),
    pu('U-000010', 'VENDOR_PORTAL', 'vendor@tirepro.ph', 'Eric Lim', '0917 300 4000', { vendor: 'V-001', desig: 'Sales Manager' }),
    pu('U-000011', 'VENDOR_PORTAL', 'sales@luzonbrake.ph', 'Gina Cruz', '0917 300 5000', { vendor: 'V-002', last: null }),
    pu('U-000012', 'VENDOR_PORTAL', 'orders@metropaint.ph', 'Paul Uy', '0917 300 6000', { vendor: 'V-003', last: t(-400) }),
    pu('U-000013', 'CLIENT_PORTAL', 'billing@abclogistics.ph', 'Carmela Santos', '0917 345 6789', { client: 'C-00123', desig: 'Billing Officer' }),
  ];
  ins('users', PORTAL);
  ins('user_roles', PORTAL.map((u) => ({ user_id: u.user_id, role_code: u.realm === 'VENDOR_PORTAL' ? 'VENDOR' : 'CLIENT' })));

  // ── Files: metadata here, placeholder content written to database/sample/files/<storage_path> ─────────
  section('Files (placeholder PDF/JPG content in database/sample/files — copy that folder into FILE_DIR on the server)');
  fs.rmSync(FILES_OUT, { recursive: true, force: true });
  const files = [];
  const file = (n, purpose, name, o) => {
    const id = uuid(n);
    const ext = name.endsWith('.pdf') ? 'pdf' : 'jpg';
    const storagePath = `${purpose.toLowerCase()}/sample/${id}.${ext}`;
    const content = ext === 'pdf' ? samplePdf(name) : TINY_JPG;
    fs.mkdirSync(path.dirname(path.join(FILES_OUT, storagePath)), { recursive: true });
    fs.writeFileSync(path.join(FILES_OUT, storagePath), content);
    files.push({ file_id: id, storage_path: storagePath, original_name: name, content_type: ext === 'pdf' ? 'application/pdf' : 'image/jpeg',
      size_bytes: content.length, sha256: null, purpose, entity_type: o.type || null, entity_id: o.id || null, owner_client_code: o.client || null, owner_vendor_id: o.vendor || null,
      upload_status: 'Uploaded', scan_status: 'Clean', scanned_at: o.at || t(-1), uploaded_by: o.by === undefined ? 'U-000001' : o.by, created_at: o.at || t(-1) });
    return id;
  };
  const F = {
    accessDoc: file(1, 'ACCESS_DOC', 'Islandlink_SEC_registration.pdf', { type: 'access_request', id: 'PAR-000004', client: 'C-00126', by: null, at: t(-2) }),
    accessDoc2: file(2, 'ACCESS_DOC', 'Islandlink_BIR_2303.jpg', { type: 'access_request', id: 'PAR-000004', client: 'C-00126', by: null, at: t(-2) }),
    tu11: file(11, 'TOPUP_PROOF', 'BDO_transfer_slip_30000.jpg', { type: 'topup', id: 'TU-000011', client: 'C-00123', at: t(-60) }),
    tu12: file(12, 'TOPUP_PROOF', 'BPI_deposit_17000.jpg', { type: 'topup', id: 'TU-000012', client: 'C-00123', at: t(-5) }),
    tu13: file(13, 'TOPUP_PROOF', 'transfer_5000.jpg', { type: 'topup', id: 'TU-000013', client: 'C-00123', at: t(-3) }),
    tu14: file(14, 'TOPUP_PROOF', 'transfer_5000_corrected.pdf', { type: 'topup', id: 'TU-000014', client: 'C-00123', at: t(-1) }),
    tu15: file(15, 'TOPUP_PROOF', 'Metrobank_check_2000.jpg', { type: 'topup', id: 'TU-000015', client: 'C-00130', by: 'U-000009', at: t(-2) }),
    tu10: file(10, 'TOPUP_PROOF', 'opening_deposit.pdf', { type: 'topup', id: 'TU-000010', client: 'C-00124', by: 'U-000003', at: t(-90) }),
    pa1: file(21, 'PAYMENT_PROOF', 'payment_INV-MNL-00001098.pdf', { type: 'payment_advice', id: 'PA-000001', client: 'C-00123', at: t(-20) }),
    pa2: file(22, 'PAYMENT_PROOF', 'payment_INV-MNL-00001101.jpg', { type: 'payment_advice', id: 'PA-000002', client: 'C-00123', at: t(-1) }),
    dsp2: file(31, 'DISPUTE_ATTACHMENT', 'gate_in_photo_DW-MNL-1005.jpg', { type: 'invoice_dispute', id: 'DSP-000002', client: 'C-00123', at: t(-3) }),
    rsc1: file(41, 'RESCUE_PHOTO', 'flat_tire_SLEX.jpg', { type: 'rescue', id: 'RSC-000041', client: 'C-00123', at: t(-20, '08:10') }),
    rsc2: file(42, 'RESCUE_PHOTO', 'brake_smoke_C5.jpg', { type: 'rescue', id: 'RSC-000042', client: 'C-00123', at: ago(95) }),
    vi1: file(51, 'VENDOR_INVOICE', 'TirePro_SI-20871.pdf', { type: 'vendor_invoice', id: 'VI-000001', vendor: 'V-001', by: 'U-000010', at: t(-25) }),
    vi2: file(52, 'VENDOR_INVOICE', 'TirePro_SI-20915.pdf', { type: 'vendor_invoice', id: 'VI-000002', vendor: 'V-001', by: 'U-000010', at: t(-9) }),
    vi3: file(53, 'VENDOR_INVOICE', 'TirePro_SI-20915-R.pdf', { type: 'vendor_invoice', id: 'VI-000003', vendor: 'V-001', by: 'U-000010', at: t(-6) }),
  };
  ins('files', files);

  // ── Portal access requests ──────────────────────────────────────────────────────────────────────
  section('Portal access requests (PAR-000004 is pending; its approval link token is in database/README.md)');
  // Known DEMO token so the reviewer's one-click page can be opened locally: /access-approval/<token>
  const APPROVAL_TOKEN = 'sample0approval0token0islandlink0000000000000000000000000000000001';
  const par = (ref, type, subject, company, o) => ({
    reference: ref, account_type: type, subject_id: subject, company_name: company, tin: enc(o.tin), tin_hash: crypto.blindIndex('tin', o.tin), branch_code: o.branch, address: o.address,
    contact_name: enc(o.contact), email: enc(o.email), email_hash: crypto.blindIndex('email', o.email), phone: enc(o.phone), privacy_consent_at: o.submitted,
    status: o.status, reviewer_label: type === 'vendor' ? 'Delbros Procurement' : 'Your Account Executive', reviewer_user_id: type === 'vendor' ? null : o.reviewer || 'AE.JREYES', applicant_user_id: o.user,
    approval_token_hash: o.token ? crypto.sha256(o.token) : null, approval_expires_at: o.expires || null, decided_at: o.decidedAt || null, decided_by: o.decidedBy || null,
    decision_reason: o.reason || null, billing_name: o.billing || null, submitted_at: o.submitted,
  });
  ins('portal_access_requests', [
    par('PAR-000001', 'client', 'C-00123', 'ABC Logistics Corp.', { tin: '123-456-789-000', branch: 'MNL', address: '1200 Road 10, Port Area, Manila', contact: 'Ana Reyes', email: 'client@abclogistics.ph', phone: '0917 123 4567', user: 'U-000001', status: 'Approved', submitted: t(-400), decidedAt: t(-399), decidedBy: 'Juan Reyes (Account Executive)', billing: 'ABC Logistics Corporation' }),
    par('PAR-000002', 'vendor', 'V-001', 'Tire Pro Supply Inc.', { tin: '901-234-567-000', branch: 'HO', address: '77 EDSA, Caloocan City', contact: 'Eric Lim', email: 'vendor@tirepro.ph', phone: '0917 300 4000', user: 'U-000010', status: 'Approved', submitted: t(-300), decidedAt: t(-298), decidedBy: 'Delbros Procurement' }),
    par('PAR-000003', 'client', 'C-00131', 'Quickhaul Express', { tin: '934-567-890-000', branch: 'LAG', address: '9 National Road, Calamba', contact: 'Leo Manalo', email: 'leo@quickhaul.ph', phone: '0917 600 7000', user: null, status: 'Rejected', submitted: t(-30), decidedAt: t(-28), decidedBy: 'Juan Reyes (Account Executive)', reason: 'Company already registered under another TIN branch; please contact your Account Executive.' }),
    par('PAR-000004', 'client', 'C-00126', 'Islandlink Cargo Services', { tin: '456-789-012-000', branch: 'BTG', address: '88 Mabini St., Batangas City', contact: 'Tess Ramirez', email: 'tess@islandlink.ph', phone: '0918 222 3344', user: 'U-000006', status: 'Submitted', submitted: t(-2), token: APPROVAL_TOKEN, expires: raw('(UTC_TIMESTAMP(3) + INTERVAL 5 DAY)') }),
  ]);

  // ── Contracts ───────────────────────────────────────────────────────────────────────────────────
  section('Contracts, rates, rate history, lifecycle events, requests');
  const contract = (no, client, type, cls, status, eff, exp, o) => ({
    contract_no: no, client_code: client, contract_type: type, contract_class: cls, status, effective_date: d(eff), expiry_date: exp === null ? null : d(exp), unit_qty: o.qty,
    entitlement_by_type: o.byType ? 1 : 0, region: o.region || 'NCR', branch_code: o.branch, signatory_contact_id: o.signatory || null, payment_method: o.pay || 'Check / bank transfer',
    billing_cycle: 'Weekly', credit_term_days: 30, cash_deposit: o.deposit, lock_in_months: o.lockIn ?? 12, min_billing_days: null,
    penalty_non_return: 5000, penalty_deferred_check: 1000, penalty_late_interest_pct: 0.02, penalty_dishonored_check: 2500,
    version_no: o.version || 1, renewal_of: o.renewalOf || null, renewed_to: o.renewedTo || null, renewal_state: o.renewalState || null, renewal_date: o.renewalDate ?? null, renewal_note: o.renewalNote || null,
    termination_reason: null, termination_date: null, ae_user_id: o.ae || 'AE.JREYES', created_by: o.ae || 'AE.JREYES',
  });
  ins('contracts', [
    contract('LTL-2024-0012', 'C-00123', 'LTL', 'A', 'Expired', -800, -70, { qty: 6, branch: 'MNL', signatory: 2, deposit: 30000, renewedTo: 'LTL-2025-0045', renewalState: 'Replaced by a new contract', renewalDate: d(-350), renewalNote: 'Replaced by LTL-2025-0045 (larger fleet)' }),
    contract('LTL-2025-0045', 'C-00123', 'LTL', 'A', 'Active', -350, 380, { qty: 12, byType: true, branch: 'MNL', signatory: 2, deposit: 60000, version: 2, renewalOf: 'LTL-2024-0012' }),
    contract('LTL-2025-0031', 'C-00123', 'LTL', 'A', 'Active', -330, 35, { qty: 4, branch: 'MNL', signatory: 2, deposit: 20000, renewalState: 'Renewal requested', renewalNote: 'Client asked for a 12-month renewal (CRQ-000002)' }),
    contract('LTL-2025-0050', 'C-00124', 'LTL', 'A', 'Active', -300, 65, { qty: 5, byType: true, branch: 'CAV', region: 'South Luzon', signatory: 3, deposit: 25000 }),
    contract('QLP-2026-0003', 'C-00125', 'QLP', 'Q', 'Active', -120, 245, { qty: 3, branch: 'CDO', region: 'Mindanao', signatory: 4, deposit: 15000, ae: 'AE.MSANTOS', lockIn: 6 }),
    contract('LTL-2025-0058', 'C-00128', 'LTL', 'A', 'Active', -200, 165, { qty: 2, branch: 'CEB', region: 'Visayas', signatory: 7, deposit: 10000, ae: 'AE.MSANTOS' }),
    contract('LTL-2024-0020', 'C-00129', 'LTL', 'A', 'Expired', -770, -40, { qty: 3, branch: 'MNL', signatory: 8, deposit: 25000, renewalState: 'Not renewed', renewalNote: 'Client is not renewing (fleet sold)' }),
    contract('LTL-2026-0002', 'C-00130', 'LTL', 'A', 'Active', -60, 305, { qty: 3, branch: 'NVL', signatory: 9, deposit: 15000 }),
  ]);
  const rates = [
    ['LTL-2024-0012', 'EQ1', 820, null], ['LTL-2024-0012', 'EQ2', 1050, null],
    ['LTL-2025-0045', 'EQ1', 850, 4], ['LTL-2025-0045', 'EQ2', 1100, 6], ['LTL-2025-0045', 'EQ4', 1250, 2], ['LTL-2025-0045', 'EQ6', 1300, 0],
    ['LTL-2025-0031', 'EQ2', 1050, null],
    ['LTL-2025-0050', 'EQ1', 850, 2], ['LTL-2025-0050', 'EQ2', 1100, 3],
    ['QLP-2026-0003', 'EQ1', 765, null], ['QLP-2026-0003', 'EQ2', 990, null],
    ['LTL-2025-0058', 'EQ2', 1100, null],
    ['LTL-2024-0020', 'EQ2', 1050, null],
    ['LTL-2026-0002', 'EQ1', 850, null], ['LTL-2026-0002', 'EQ2', 1100, null],
  ];
  const rateOf = Object.fromEntries(rates.map(([c, e, r]) => [`${c}|${e}`, r]));
  ins('contract_rates', rates.map(([c, e, r, q]) => ({ contract_no: c, equipment_type: e, daily_rate: r, indemnity: r * 400, entitled_qty: q, template_rate: base[e] })));
  ins('contract_rate_versions', [
    { contract_no: 'LTL-2025-0045', version_no: 1, valid_from: d(-350), valid_to: d(-121), reason: 'Initial contract rates', created_by: 'AE.JREYES', created_at: t(-352) },
    { contract_no: 'LTL-2025-0045', version_no: 2, valid_from: d(-120), valid_to: null, reason: 'Amendment CRQ-000001: EQ4 combo units added, EQ2 rate adjusted', created_by: 'AE.JREYES', created_at: t(-121) },
    ...rates.filter(([c]) => c !== 'LTL-2025-0045').map(([c]) => c).filter((c, i, a) => a.indexOf(c) === i).map((c) => ({ contract_no: c, version_no: 1, valid_from: { 'LTL-2024-0012': d(-800), 'LTL-2025-0031': d(-330), 'LTL-2025-0050': d(-300), 'QLP-2026-0003': d(-120), 'LTL-2025-0058': d(-200), 'LTL-2024-0020': d(-770), 'LTL-2026-0002': d(-60) }[c], valid_to: null, reason: 'Initial contract rates', created_by: 'AE.JREYES', created_at: t(-360) })),
  ]);
  ins('contract_rate_version_lines', [
    { contract_no: 'LTL-2025-0045', version_no: 1, equipment_type: 'EQ1', daily_rate: 850 }, { contract_no: 'LTL-2025-0045', version_no: 1, equipment_type: 'EQ2', daily_rate: 1080 },
    ...rates.map(([c, e, r]) => ({ contract_no: c, version_no: c === 'LTL-2025-0045' ? 2 : 1, equipment_type: e, daily_rate: r })),
  ]);
  ins('contract_events', [
    ['LTL-2024-0012', 'Active', t(-800), 'AE.JREYES', null], ['LTL-2024-0012', 'Expired', t(-70, '00:10'), 'system', 'Contract end date reached'],
    ['LTL-2025-0045', 'Draft', t(-360), 'AE.JREYES', null], ['LTL-2025-0045', 'Signed', t(-355), 'AE.JREYES', 'Signed by Roberto Lim'], ['LTL-2025-0045', 'Notarized', t(-352), 'AE.JREYES', null],
    ['LTL-2025-0045', 'Active', t(-350), 'AE.JREYES', null], ['LTL-2025-0045', 'Amended (v2)', t(-120), 'AE.JREYES', 'CRQ-000001 approved: EQ4 added'],
    ['LTL-2025-0031', 'Active', t(-330), 'AE.JREYES', null], ['LTL-2025-0031', 'Renewal notice — 3 months', t(-57, '00:10'), 'system', 'Emailed to the client and the Account Executive'],
    ['LTL-2025-0031', 'Renewal notice — 2 months', t(-26, '00:10'), 'system', 'Emailed to the client and the Account Executive'], ['LTL-2025-0031', 'Renewal requested', t(-4), 'U-000001', 'CRQ-000002'],
    ['LTL-2025-0050', 'Active', t(-300), 'AE.JREYES', null], ['QLP-2026-0003', 'Active', t(-120), 'AE.MSANTOS', null], ['LTL-2025-0058', 'Active', t(-200), 'AE.MSANTOS', null],
    ['LTL-2024-0020', 'Active', t(-770), 'AE.JREYES', null], ['LTL-2024-0020', 'Expired', t(-40, '00:10'), 'system', 'Contract end date reached — not renewed'], ['LTL-2026-0002', 'Active', t(-60), 'AE.JREYES', null],
  ].map(([c, s, at, by, note]) => ({ contract_no: c, status_label: s, event_at: at, event_by: by, note, file_id: null })));
  ins('contract_requests', [
    { request_id: 'CRQ-000001', client_code: 'C-00123', contract_no: 'LTL-2025-0045', kind: 'Amendment', details: 'Please add 2 units of 40ft combo (EQ4) to the contract.', term_months: null, change_area: 'Equipment types', effective_date: d(-120), fee_estimate: null, status: 'Approved', submitted_at: t(-135), submitted_by: 'U-000001', decided_at: t(-121), decided_by: 'AE.JREYES', decision_note: 'Approved — rate version 2 effective.' },
    { request_id: 'CRQ-000002', client_code: 'C-00123', contract_no: 'LTL-2025-0031', kind: 'Renewal', details: 'We would like to renew for another 12 months at the same rates.', term_months: 12, change_area: null, effective_date: null, fee_estimate: null, status: 'Under review', submitted_at: t(-4), submitted_by: 'U-000001', decided_at: null, decided_by: null, decision_note: null },
  ]);

  // ── Chassis, EWAs, gate passes, EIRs ────────────────────────────────────────────────────────────
  section('Chassis, EWAs, gate passes (OUT/IN), inspection lines, EIRs, return requests');
  const DRIVERS = { a: ['Ramil Santos', 'N01-12-345678'], b: ['Jun dela Peña', 'N02-15-112233'], c: ['Edwin Ocampo', 'D04-18-998877'], d: ['Arnel Bautista', 'K05-19-445566'], e: ['Rolando Uy', 'H06-20-667788'] };
  const TRUCKS = { a: ['ABC Trucking (own fleet)', 'NAB 5678', 'OR-1928374'], b: ['ABC Trucking (own fleet)', 'NCQ 2231', 'OR-2837465'], c: ['Speedway Haulers', 'CAV 1122', null], d: ['Mindanao Truckers Coop', 'KAA 4455', 'OR-9988776'], e: ['Metro Haul Services', 'NXY 7788', null] };

  // On hire / returned units. out = day offset of Gate Out; inAt = Gate In offset (returned units)
  const units = [
    // chassis, type, release branch, client, contract, EWA, gate out no, out day, status, truck/driver key, [gate in no, in day, in branch]
    ['DW-MNL-1001', 'EQ2', 'MNL', 'C-00123', 'LTL-2025-0045', 'EU-000781', 'MNL0881', -40, 'On Hire', 'a'],
    ['DW-MNL-1002', 'EQ2', 'MNL', 'C-00123', 'LTL-2025-0045', 'EU-000781', 'MNL0882', -40, 'On Hire', 'a'],
    ['DW-CAV-2001', 'EQ1', 'CAV', 'C-00123', 'LTL-2025-0045', 'EU-000782', 'CAV0441', -33, 'On Hire', 'b'],
    ['DW-MNL-1003', 'EQ4', 'MNL', 'C-00123', 'LTL-2025-0045', 'EU-000783', 'MNL0883', -30, 'Rescue', 'a'],
    ['DW-LAG-3001', 'EQ2', 'LAG', 'C-00123', 'LTL-2025-0045', 'EU-000784', 'LAG0201', -25, 'On Hire', 'b'],
    ['DW-MNL-1004', 'EQ2', 'MNL', 'C-00123', 'LTL-2025-0031', 'EU-000785', 'MNL0879', -45, 'On Hire', 'a'],
    ['DW-MNL-1005', 'EQ2', 'MNL', 'C-00123', 'LTL-2025-0045', 'EU-000770', 'MNL0850', -60, 'Available', 'a', 'MNL0890', -10, 'MNL'],
    ['DW-CAV-2004', 'EQ1', 'CAV', 'C-00123', 'LTL-2024-0012', 'EU-000771', 'CAV0430', -200, 'Available', 'b', 'MNL0891', -75, 'MNL'],
    ['DW-CAV-2002', 'EQ1', 'CAV', 'C-00124', 'LTL-2025-0050', 'EU-000775', 'CAV0435', -95, 'On Hire', 'c'],
    ['DW-CAV-2003', 'EQ2', 'CAV', 'C-00124', 'LTL-2025-0050', 'EU-000775', 'CAV0436', -95, 'On Hire', 'c'],
    ['DW-CDO-5001', 'EQ1', 'CDO', 'C-00125', 'QLP-2026-0003', 'EU-000776', 'CDO0112', -50, 'On Hire', 'd'],
    ['DW-CEB-6001', 'EQ2', 'CEB', 'C-00128', 'LTL-2025-0058', 'EU-000777', 'CEB0301', -70, 'On Hire', 'd'],
    ['DW-MNL-1006', 'EQ2', 'MNL', 'C-00129', 'LTL-2024-0020', 'EU-000760', 'MNL0801', -150, 'Available', 'e', 'MNL0870', -42, 'MNL'],
    ['DW-NVL-4001', 'EQ2', 'NVL', 'C-00130', 'LTL-2026-0002', 'EU-000778', 'NVL0151', -21, 'On Hire', 'e'],
  ];
  const pool = [
    ['DW-MNL-1010', 'EQ1', 'MNL'], ['DW-MNL-1011', 'EQ1', 'MNL'], ['DW-MNL-1012', 'EQ2', 'MNL'], ['DW-MNL-1013', 'EQ2', 'MNL'], ['DW-MNL-1014', 'EQ2', 'MNL'], ['DW-MNL-1015', 'EQ4', 'MNL'],
    ['DW-CAV-2010', 'EQ1', 'CAV'], ['DW-CAV-2011', 'EQ2', 'CAV'], ['DW-CAV-2012', 'EQ2', 'CAV'], ['DW-LAG-3010', 'EQ2', 'LAG'], ['DW-LAG-3011', 'EQ4', 'LAG'],
    ['DW-NVL-4010', 'EQ1', 'NVL'], ['DW-NVL-4011', 'EQ2', 'NVL'], ['DW-CDO-5010', 'EQ1', 'CDO'], ['DW-CDO-5011', 'EQ2', 'CDO'], ['DW-DVO-7001', 'EQ2', 'DVO'], ['DW-CEB-6010', 'EQ2', 'CEB'],
  ];
  const chassisRows = [
    ...units.map(([no, type, br, client, contract, , gp, outDay, status, , gin, inDay, inBr]) => ({
      chassis_no: no, chassis_type: type, plate_no: `DW${no.slice(-4)}`, branch_code: gin ? inBr : br, status, status_since: gin ? t(inDay, '14:00') : status === 'Rescue' ? ago(95) : t(outDay, '10:00'),
      owner: 'Delbros', standard: 'DW', general_assessment: 'Roadworthy', current_client_code: gin ? null : client, current_contract_no: gin ? null : contract, current_gate_pass_no: gin ? null : gp,
      axle_config: type === 'EQ1' ? '2-axle' : '3-axle', hub_type: '10-hole', remarks: null,
    })),
    ...pool.map(([no, type, br]) => ({ chassis_no: no, chassis_type: type, plate_no: `DW${no.slice(-4)}`, branch_code: br, status: 'Available', status_since: t(-15), owner: 'Delbros', standard: br === 'CDO' || br === 'DVO' ? 'Nakamura' : 'DW',
      general_assessment: 'Roadworthy', current_client_code: null, current_contract_no: null, current_gate_pass_no: null, axle_config: type === 'EQ1' ? '2-axle' : '3-axle', hub_type: '10-hole', remarks: null })),
    { chassis_no: 'DW-MNL-1020', chassis_type: 'EQ2', plate_no: 'DW1020', branch_code: 'MNL', status: 'In Repair', status_since: t(-3), owner: 'Delbros', standard: 'DW', general_assessment: 'Unroadworthy', current_client_code: null, current_contract_no: null, current_gate_pass_no: null, axle_config: '3-axle', hub_type: '10-hole', remarks: 'Axle repair' },
  ];
  ins('chassis', chassisRows);

  // EWAs: released ones (Used) built from the units; plus open / expired / cancelled ones for ABC.
  const ewaRows = []; const ewaLines = []; const ewaReleased = [];
  const byEwa = {};
  for (const u of units) (byEwa[u[5]] ??= []).push(u);
  for (const [eu, us] of Object.entries(byEwa)) {
    const [, , br, client, contract, , , outDay, , key] = us[0];
    const [dn, lic] = DRIVERS[key]; const [trucker, plate, orcr] = TRUCKS[key];
    ewaRows.push({ eu_no: eu, client_code: client, contract_no: contract, branch_code: br, trucker, truck_plate_no: plate, truck_orcr: orcr, driver_name: enc(dn), driver_license_no: enc(lic), driver_license_hash: crypto.blindIndex('licence', lic),
      expected_pickup_at: t(outDay, '08:00'), remarks: null, status: 'Used', created_via: 'Portal', created_by: client === 'C-00123' ? 'U-000001' : { 'C-00124': 'U-000003', 'C-00125': 'U-000004', 'C-00128': 'U-000007', 'C-00129': 'U-000008', 'C-00130': 'U-000009' }[client],
      created_at: t(outDay - 1, '15:00'), valid_until: t(outDay, '15:00'), extension_count: 0, cancelled_at: null, cancelled_by: null, cancel_reason: null, expired_lapsed_units: null });
    const qty = {};
    for (const u of us) qty[u[1]] = (qty[u[1]] || 0) + 1;
    for (const [eq, q] of Object.entries(qty)) ewaLines.push({ eu_no: eu, equipment_type: eq, qty: q });
    for (const u of us) ewaReleased.push({ eu_no: eu, equipment_type: u[1], chassis_no: u[0], gate_pass_no: u[6], released_at: t(u[7], '10:00') });
  }
  const openEwa = (eu, br, status, created, valid, lines, key, o = {}) => {
    const [dn, lic] = DRIVERS[key]; const [trucker, plate, orcr] = TRUCKS[key];
    ewaRows.push({ eu_no: eu, client_code: 'C-00123', contract_no: o.contract || 'LTL-2025-0045', branch_code: br, trucker, truck_plate_no: plate, truck_orcr: orcr, driver_name: enc(dn), driver_license_no: enc(lic), driver_license_hash: crypto.blindIndex('licence', lic),
      expected_pickup_at: o.pickup || null, remarks: o.remarks || null, status, created_via: 'Portal', created_by: 'U-000001', created_at: created, valid_until: valid, extension_count: 0,
      cancelled_at: o.cancelledAt || null, cancelled_by: o.cancelledAt ? 'U-000001' : null, cancel_reason: o.cancelReason || null, expired_lapsed_units: o.lapsed ?? null });
    for (const [eq, q] of lines) ewaLines.push({ eu_no: eu, equipment_type: eq, qty: q });
  };
  openEwa('EU-000786', 'CAV', 'Expired', t(-15, '14:00'), t(-14, '14:00'), [['EQ1', 1]], 'b', { lapsed: 1, remarks: 'Truck broke down — not picked up' });
  openEwa('EU-000787', 'MNL', 'Cancelled', t(-8, '09:30'), t(-7, '09:30'), [['EQ2', 1]], 'a', { cancelledAt: t(-8, '11:00'), cancelReason: 'Booking moved to next week by the shipping line' });
  openEwa('EU-000789', 'CAV', 'Extension Pending', ago(20 * 60), ahead(4 * 60), [['EQ1', 1]], 'b', { pickup: ahead(3 * 60), remarks: 'Port congestion' });
  openEwa('EU-000790', 'MNL', 'Active', ago(120), ahead(22 * 60), [['EQ1', 1], ['EQ2', 1]], 'a', { pickup: ahead(5 * 60), remarks: 'Gate 2, export booking BK-77812' });
  ins('ewas', ewaRows);
  ins('ewa_lines', ewaLines);

  const gp = []; const inspection = []; const eirs = [];
  for (const u of units) {
    const [no, type, br, client, contract, eu, gpOut, outDay, , key, gin, inDay, inBr] = u;
    const [dn, lic] = DRIVERS[key]; const [trucker, plate, orcr] = TRUCKS[key];
    const eir = `EIR-${br}-${String(100000 + Number(gpOut.slice(3))).slice(1)}`;
    gp.push({ gate_pass_no: gpOut, direction: 'OUT', chassis_no: no, client_code: client, contract_no: contract, eu_no: eu, branch_code: br, origin_branch_code: null, cross_branch_code: null,
      trucker, truck_plate_no: plate, truck_orcr: orcr, driver_name: enc(dn), driver_license_no: enc(lic), general_assessment: 'Roadworthy', flat_tires: 0, vandalized: 0, signature_file_id: null,
      actual_event_at: t(outDay, '10:00'), encoded_at: t(outDay, '10:05'), encoded_by: `BG.${br}`.replace('BG.MNL', 'BG.MNL.PDIAZ').replace('BG.CAV', 'BG.CAV.RGARCIA').replace('BG.LAG', 'BG.LAG.NVILLAR').replace('BG.NVL', 'BG.NVL.SPEREZ').replace('BG.CDO', 'BG.CDO.ALIM').replace('BG.CEB', 'BG.CEB'),
      is_force_inbound: 0, eir_no: eir, paired_gate_pass_no: gin || null, remarks: null });
    for (const [i, part] of ['Tires (8)', 'Lights', 'Twist locks'].entries()) inspection.push({ gate_pass_no: gpOut, line_no: i + 1, part, branding: part.startsWith('Tires') ? 'Bridgestone' : null, thread_depth: part.startsWith('Tires') ? '12mm' : null, status_code: 'OK', qty: part.startsWith('Tires') ? 8 : 1, chargeable: 0 });
    if (gin) {
      const cross = inBr !== br;
      gp.push({ gate_pass_no: gin, direction: 'IN', chassis_no: no, client_code: client, contract_no: contract, eu_no: null, branch_code: inBr, origin_branch_code: cross ? br : null, cross_branch_code: cross ? 'XB-7G3K' : null,
        trucker, truck_plate_no: plate, truck_orcr: orcr, driver_name: enc(dn), driver_license_no: enc(lic), general_assessment: no === 'DW-MNL-1005' ? 'Unroadworthy' : 'Roadworthy', flat_tires: no === 'DW-MNL-1005' ? 1 : 0, vandalized: 0, signature_file_id: null,
        actual_event_at: t(inDay, '14:00'), encoded_at: t(inDay, '14:10'), encoded_by: 'BG.MNL.PDIAZ', is_force_inbound: 0, eir_no: eir, paired_gate_pass_no: gpOut,
        remarks: no === 'DW-MNL-1005' ? 'Rear left outer tire cut; mud flap missing' : cross ? 'Cross-branch return approved by IT (BR-16)' : null });
      if (no === 'DW-MNL-1005') {
        inspection.push({ gate_pass_no: gin, line_no: 1, part: 'Tire — rear left outer (cut)', branding: 'Bridgestone', thread_depth: '3mm', status_code: 'DAMAGED', qty: 1, chargeable: 3000 });
        inspection.push({ gate_pass_no: gin, line_no: 2, part: 'Mud flap (missing)', branding: null, thread_depth: null, status_code: 'MISSING', qty: 1, chargeable: 1500 });
        inspection.push({ gate_pass_no: gin, line_no: 3, part: 'Lights', branding: null, thread_depth: null, status_code: 'OK', qty: 1, chargeable: 0 });
      } else {
        inspection.push({ gate_pass_no: gin, line_no: 1, part: 'Tires (8)', branding: 'Bridgestone', thread_depth: '9mm', status_code: 'OK', qty: 8, chargeable: 0 });
      }
    }
    eirs.push({ eir_no: eir, gate_pass_out_no: gpOut, gate_pass_in_no: gin || null, client_code: client, chassis_no: no, chassis_type: type, contract_no: contract, depot_code: br,
      eir_out_date: t(outDay, '10:00'), eir_in_date: gin ? t(inDay, '14:00') : null, booking_no: `BK-${70000 + Number(gpOut.slice(3))}`, reprint_count: 0 });
  }
  // encoded_by must be a real-looking staff id; CEB has no generalist in the sample → AE.MSANTOS
  for (const g of gp) if (g.encoded_by === 'BG.CEB') g.encoded_by = 'AE.MSANTOS';
  ins('gate_passes', gp);
  ins('gate_pass_inspection_lines', inspection);
  ins('eirs', eirs);
  ins('ewa_line_chassis', ewaReleased);
  ins('ewa_extensions', [
    { eu_no: 'EU-000789', requested_at: ago(60), requested_by: 'U-000001', reason: 'Port congestion — the truck reaches the yard after the validity ends.', workflow_id: 'WF-00003', status: 'Pending', decided_at: null, decided_by: null, valid_until_before: ahead(4 * 60), valid_until_after: null },
  ]);
  ins('return_requests', [
    { request_no: 'RTN-000001', client_code: 'C-00123', chassis_no: 'DW-MNL-1005', contract_no: 'LTL-2025-0045', origin_branch_code: 'MNL', return_branch_code: 'MNL', preferred_date: d(-10), notes: 'Unit has a damaged tire', status: 'Completed', requested_at: t(-13), requested_by: 'U-000001' },
    { request_no: 'RTN-000002', client_code: 'C-00123', chassis_no: 'DW-LAG-3001', contract_no: 'LTL-2025-0045', origin_branch_code: 'LAG', return_branch_code: 'LAG', preferred_date: d(3), notes: 'Please collect in the morning', status: 'Requested', requested_at: t(-1, '16:00'), requested_by: 'U-000001' },
  ]);

  // ── Rescues ─────────────────────────────────────────────────────────────────────────────────────
  section('Rescues (completed with costs, open/dispatched, cancelled) and their status log');
  const travel = 18 * 2 * 60; // one-way km × 2 × rate per km
  const rescueTotal = r2((travel + 16800) * 1.10); // tire at rescue price + 10 % service fee (BR-11)
  const rescue = (no, chassis, gpOut, status, at, o) => ({
    rescue_no: no, client_code: 'C-00123', chassis_no: chassis, gate_pass_out_no: gpOut, branch_code: 'MNL', location_text: o.loc, lat: o.lat, lng: o.lng, problem_type: o.problem, problem_detail: o.detail || null,
    incident: o.incident, load_status: o.load || 'Loaded', scene_contact_name: enc(o.contact[0]), scene_contact_phone: enc(o.contact[1]), is_urgent: o.urgent ? 1 : 0, status, requested_at: at, requested_via: 'Portal', requested_by: 'U-000001',
    blocked_reason: null, verified_by: o.verified ? 'RSC.DMORALES' : null, confirmed_by: o.verified ? 'RSC.DMORALES' : null, crew: o.crew || null, rescue_vehicle: o.vehicle || null,
    driver_name: o.crew ? enc('Ruben Castillo') : null, driver_phone: o.crew ? enc('0917 800 5566') : null, dispatched_at: o.dispatched || null, eta: o.eta || null, onsite_assessment: o.assessment || null,
    completed_at: o.completed || null, completed_by: o.completed ? 'RSC.DMORALES' : null, client_ack_name: o.completed ? 'R. Santos (driver)' : null, acknowledged_at: o.completed || null, is_chargeable: 1,
    one_way_km: o.completed ? 18 : null, rate_per_km: o.completed ? 60 : null, tire_cost: o.completed ? 16800 : null, parts_cost: o.completed ? 0 : null, total: o.completed ? rescueTotal : null,
    debit_memo_no: o.completed ? 'DM-000039' : null, ewallet_balance_after: o.balanceAfter ?? null, cancel_reason: o.cancelReason || null, cancelled_by: o.cancelReason ? 'U-000001' : null, cancelled_at: o.cancelledAt || null,
  });
  // e-wallet balances (computed below, the rescue deduction is the 2nd ABC transaction)
  const abcTx = [
    ['EWT-000101', t(-60, '11:00'), 'Replenishment', 'Top-up', 30000, 'Top-up', 'TU-000011', 'OR-MNL-00000290', 'TRS.ELOPEZ', 'Top-up TU-000011 confirmed by Treasury'],
    ['EWT-000102', t(-19, '18:30'), 'Deduction', 'Rescue', -rescueTotal, 'Rescue', 'RSC-000041', null, 'ACC.BVILLA', 'Rescue RSC-000041 (DM-000039)'],
    ['EWT-000103', t(-12, '10:00'), 'Deduction', 'Repair', -3200, 'Job Order', 'JO-000118', null, 'ACC.BVILLA', 'Brake lining replacement DW-MNL-1002'],
    ['EWT-000104', t(-5, '15:00'), 'Replenishment', 'Top-up', 17000, 'Top-up', 'TU-000012', 'OR-MNL-00000307', 'TRS.ELOPEZ', 'Top-up TU-000012 confirmed by Treasury'],
    ['EWT-000105', t(-2, '09:00'), 'Adjustment', 'Adjustment', 500, 'Adjustment', 'ADJ-000004', null, 'ACC.BVILLA', 'Goodwill credit: rescue response delay'],
  ];
  let bal = 0; const abcRows = [];
  for (const [id, at, type, cat, amt, rtype, rid, rcpt, by, reason] of abcTx) {
    bal = r2(bal + amt);
    abcRows.push({ txn_id: id, client_code: 'C-00123', txn_at: at, txn_type: type, category: cat, amount: amt, balance_after: bal, reference_type: rtype, reference_id: rid, receipt_no: rcpt, treasury_ref: cat === 'Top-up' ? `TRS-${id.slice(-3)}` : null,
      posted_directly_by_treasury: 0, reverses_txn_id: null, reversed_by_txn_id: null, reason, posted_by: by });
  }
  ins('rescues', [
    rescue('RSC-000041', 'DW-MNL-1002', 'MNL0882', 'Completed', t(-20, '08:00'), { loc: 'SLEX northbound km 32, near Santa Rosa exit', lat: 14.312345, lng: 121.098765, problem: 'Flat / blown tire', detail: 'Rear right outer tire blown', incident: 'Tire blew while travelling loaded to Manila port.', contact: ['Ramil Santos', '0917 222 3344'], verified: true, crew: 'Team Alpha (2)', vehicle: 'Service van SV-02', dispatched: t(-20, '08:20'), eta: t(-20, '09:15'), assessment: 'Tire replaced on site (11.00R20).', completed: t(-20, '10:05'), balanceAfter: abcRows[1].balance_after }),
    rescue('RSC-000042', 'DW-MNL-1003', 'MNL0883', 'Dispatched', ago(100), { loc: 'C-5 Road southbound, Taguig (near Market! Market!)', lat: 14.549876, lng: 121.055432, problem: 'Brake problem', detail: 'Brake smoke, driver stopped', incident: 'Driver noticed smoke from the rear brake drum and pulled over.', contact: ['Jun dela Peña', '0918 333 4455'], urgent: true, verified: true, crew: 'Team Bravo (2)', vehicle: 'Service van SV-05', dispatched: ago(70), eta: ahead(25) }),
    rescue('RSC-000043', 'DW-CAV-2001', 'CAV0441', 'Cancelled', t(-6, '13:00'), { loc: 'Aguinaldo Highway, Imus', lat: 14.401234, lng: 120.941234, problem: 'Electrical / lights', incident: 'Tail lights not working.', contact: ['Jun dela Peña', '0918 333 4455'], load: 'Empty', cancelReason: 'Driver fixed the loose connector', cancelledAt: t(-6, '13:40') }),
  ]);
  ins('rescue_status_log', [
    ['RSC-000041', 'Requested', t(-20, '08:00'), 'U-000001'], ['RSC-000041', 'Verified', t(-20, '08:05'), 'RSC.DMORALES'], ['RSC-000041', 'Confirmed', t(-20, '08:10'), 'RSC.DMORALES'],
    ['RSC-000041', 'Dispatched', t(-20, '08:20'), 'RSC.DMORALES'], ['RSC-000041', 'In Progress', t(-20, '09:20'), 'RSC.DMORALES'], ['RSC-000041', 'Completed', t(-20, '10:05'), 'RSC.DMORALES'],
    ['RSC-000042', 'Requested', ago(100), 'U-000001'], ['RSC-000042', 'Verified', ago(90), 'RSC.DMORALES'], ['RSC-000042', 'Confirmed', ago(85), 'RSC.DMORALES'], ['RSC-000042', 'Dispatched', ago(70), 'RSC.DMORALES'],
    ['RSC-000043', 'Requested', t(-6, '13:00'), 'U-000001'], ['RSC-000043', 'Cancelled', t(-6, '13:40'), 'U-000001'],
  ].map(([n, s, at, by]) => ({ rescue_no: n, status: s, status_at: at, status_by: by })));
  ins('rescue_cost_lines', [{ rescue_no: 'RSC-000041', line_no: 1, kind: 'Tire', part_code: 'TIRE-1100R20', description: 'Tire 11.00R20 (radial)', qty: 1, unit_price: 16800 }]);

  // ── Invoices, receipts, memos, proof of payment, disputes, SOA ─────────────────────────────────
  section('Invoices (paid, partially paid + overdue, unpaid, awaiting acknowledgment, repair, cancelled) with lines');
  const invRows = []; const invLines = []; const invEvents = [];
  const lease = (chassis, type, contract, from, to) => { const days = to - from + 1; const rate = rateOf[`${contract}|${type}`]; return { line_type: 'Lease', description: `Lease ${chassis} (${type}) ${days} day(s)`, chassis_no: chassis, equipment_type: type, rate_type: 'Daily', from, to, days, rate, amount: r2(days * rate) }; };
  const invoice = (no, client, contract, br, billType, date, period, lines, o = {}) => {
    const subtotal = r2(lines.reduce((a, l) => a + l.amount, 0)); const vat = r2(subtotal * 0.12); const total = r2(subtotal + vat);
    const paid = o.paid === 'all' ? total : o.paid || 0;
    invRows.push({ invoice_no: no, client_code: client, contract_no: contract, branch_code: br, bill_type: billType, billing_cycle: billType === 'Lease' ? 'Weekly' : null, batch_no: billType === 'Lease' ? `BAT-${no.slice(-4)}` : null,
      invoice_date: d(date), period_start: d(period[0]), period_end: d(period[1]), subtotal, vat, total, amount_paid: paid, credited: o.credited || 0, credit_term_days: 30,
      due_basis: o.ack === undefined ? 'Invoice date' : 'Acknowledgment', due_date: o.ack === null ? null : d((o.ack ?? date) + 30),
      acknowledged_at: o.ack === undefined || o.ack === null ? null : t(o.ack, '10:30'), acknowledged_by: o.ack === undefined || o.ack === null ? null : o.ackBy || 'U-000001', acknowledged_via: o.ack === undefined || o.ack === null ? null : 'Portal',
      status: o.status || 'Sent', issued_at: t(date, '17:00'), sent_to: enc(o.sentTo || 'billing@abclogistics.ph'), sent_at: t(date, '17:05'), held_reason: null, cancel_reason: o.cancelReason || null, print_count: 0 });
    lines.forEach((l, i) => invLines.push({ invoice_no: no, line_no: i + 1, line_type: l.line_type, description: l.description, chassis_no: l.chassis_no || null, equipment_type: l.equipment_type || null, rate_type: l.rate_type || null,
      date_from: l.from === undefined ? null : d(l.from), date_to: l.to === undefined ? null : d(l.to), days: l.days ?? null, rate: l.rate ?? null, amount: l.amount, is_held: 0 }));
    invEvents.push({ invoice_no: no, event_at: t(date, '16:00'), event_by: 'ACC.BVILLA', action: 'Finalized', note: null });
    invEvents.push({ invoice_no: no, event_at: t(date, '17:05'), event_by: 'system', action: 'Sent', note: 'Emailed to the e-billing address' });
    if (o.ack !== undefined && o.ack !== null) invEvents.push({ invoice_no: no, event_at: t(o.ack, '10:30'), event_by: o.ackBy || 'U-000001', action: 'Acknowledged', note: 'Acknowledged in the portal — credit term starts' });
    if (o.cancelReason) invEvents.push({ invoice_no: no, event_at: t(date + 1, '09:00'), event_by: 'ACC.BVILLA', action: 'Cancelled', note: o.cancelReason });
    return total;
  };
  const A = 'LTL-2025-0045'; const B = 'LTL-2025-0031';
  const tot1095 = invoice('INV-MNL-00001095', 'C-00123', A, 'MNL', 'Lease', -46, [-60, -47], [lease('DW-MNL-1005', 'EQ2', A, -60, -47)], { paid: 'all' });
  const lines1098 = [lease('DW-MNL-1005', 'EQ2', A, -46, -33), lease('DW-MNL-1004', 'EQ2', B, -45, -33), lease('DW-MNL-1001', 'EQ2', A, -40, -33), lease('DW-MNL-1002', 'EQ2', A, -40, -33), lease('DW-CAV-2001', 'EQ1', A, -33, -33)];
  invoice('INV-MNL-00001098', 'C-00123', A, 'MNL', 'Lease', -32, [-46, -33], lines1098, { paid: 20000, credited: 1200 });
  invoice('INV-MNL-00001099', 'C-00123', A, 'MNL', 'Lease', -31, [-46, -33], [lease('DW-MNL-1001', 'EQ2', A, -40, -33)], { status: 'Cancelled', cancelReason: 'Duplicate of INV-MNL-00001098' });
  invoice('INV-MNL-00001101', 'C-00123', A, 'MNL', 'Lease', -18, [-32, -19], [lease('DW-MNL-1005', 'EQ2', A, -32, -19), lease('DW-MNL-1004', 'EQ2', B, -32, -19), lease('DW-MNL-1001', 'EQ2', A, -32, -19), lease('DW-MNL-1002', 'EQ2', A, -32, -19),
    lease('DW-CAV-2001', 'EQ1', A, -32, -19), lease('DW-MNL-1003', 'EQ4', A, -30, -19), lease('DW-LAG-3001', 'EQ2', A, -25, -19)], { ack: -16 });
  const tot1102 = invoice('INV-MNL-00001102', 'C-00123', A, 'MNL', 'Repair', -9, [-10, -10], [
    { line_type: 'Damage', description: 'Gate In damage DW-MNL-1005: tire rear left outer (cut)', chassis_no: 'DW-MNL-1005', amount: 3000 },
    { line_type: 'Damage', description: 'Gate In damage DW-MNL-1005: mud flap (missing)', chassis_no: 'DW-MNL-1005', amount: 1500 }], { ack: -8 });
  invoice('INV-MNL-00001104', 'C-00123', A, 'MNL', 'Lease', -4, [-18, -5], [lease('DW-MNL-1005', 'EQ2', A, -18, -10), lease('DW-MNL-1004', 'EQ2', B, -18, -5), lease('DW-MNL-1001', 'EQ2', A, -18, -5), lease('DW-MNL-1002', 'EQ2', A, -18, -5),
    lease('DW-CAV-2001', 'EQ1', A, -18, -5), lease('DW-MNL-1003', 'EQ4', A, -18, -5), lease('DW-LAG-3001', 'EQ2', A, -18, -5)], { ack: null });
  // Pacific Movers (on hold): one invoice > 30 days past due, one current
  const C = 'LTL-2025-0050';
  invoice('INV-CAV-00000501', 'C-00124', C, 'CAV', 'Lease', -80, [-94, -81], [lease('DW-CAV-2002', 'EQ1', C, -94, -81), lease('DW-CAV-2003', 'EQ2', C, -94, -81)], { sentTo: 'accounts@pacificmovers.ph' });
  invoice('INV-CAV-00000507', 'C-00124', C, 'CAV', 'Lease', -25, [-39, -26], [lease('DW-CAV-2002', 'EQ1', C, -39, -26), lease('DW-CAV-2003', 'EQ2', C, -39, -26)], { sentTo: 'accounts@pacificmovers.ph', ack: -24, ackBy: 'U-000003' });
  // Southern Haulers (Nakamura billing): one paid, one open
  const Q = 'QLP-2026-0003';
  const totCdo18 = invoice('INV-CDO-00000018', 'C-00125', Q, 'CDO', 'Lease', -26, [-40, -27], [lease('DW-CDO-5001', 'EQ1', Q, -40, -27)], { paid: 'all', sentTo: 'accounts@southernhaulers.ph' });
  invoice('INV-CDO-00000021', 'C-00125', Q, 'CDO', 'Lease', -12, [-26, -13], [lease('DW-CDO-5001', 'EQ1', Q, -26, -13)], { sentTo: 'accounts@southernhaulers.ph', ack: -11, ackBy: 'U-000004' });
  // Bayside (contract ended, everything paid) and Metro (one open)
  const L20 = 'LTL-2024-0020';
  const totBay = invoice('INV-MNL-00001050', 'C-00129', L20, 'MNL', 'Lease', -41, [-55, -42], [lease('DW-MNL-1006', 'EQ2', L20, -55, -42)], { paid: 'all', sentTo: 'finance@baysidehaulage.ph' });
  const M = 'LTL-2026-0002';
  invoice('INV-NVL-00000301', 'C-00130', M, 'NVL', 'Lease', -6, [-20, -7], [lease('DW-NVL-4001', 'EQ2', M, -20, -7)], { sentTo: 'ops@metrocontainer.ph', ack: -5, ackBy: 'U-000009' });
  ins('invoices', invRows);
  ins('invoice_lines', invLines);

  ins('receipts', [
    { receipt_no: 'OR-MNL-00000296', receipt_type: 'OR', client_code: 'C-00123', receipt_date: d(-20), amount: tot1095, unapplied: 0, method: 'Bank transfer', reference: 'BDO-778812', status: 'OR Issued', or_no: null, pr_no: null, check_no: null, check_bank: null, check_date: null, is_pdc: 0, deposit_status: 'Cleared', cleared_at: t(-19), cleared_by: 'TRS.ELOPEZ', created_by: 'ACC.BVILLA' },
    { receipt_no: 'OR-MNL-00000302', receipt_type: 'OR', client_code: 'C-00123', receipt_date: d(-15), amount: 20000, unapplied: 0, method: 'Check', reference: 'Check 004512', status: 'OR Issued', or_no: null, pr_no: null, check_no: '004512', check_bank: 'BPI', check_date: d(-16), is_pdc: 0, deposit_status: 'Cleared', cleared_at: t(-14), cleared_by: 'TRS.ELOPEZ', created_by: 'ACC.BVILLA' },
    { receipt_no: 'OR-CDO-00000011', receipt_type: 'OR', client_code: 'C-00125', receipt_date: d(-10), amount: totCdo18, unapplied: 0, method: 'Bank transfer', reference: 'LBP-55120', status: 'OR Issued', or_no: null, pr_no: null, check_no: null, check_bank: null, check_date: null, is_pdc: 0, deposit_status: 'Cleared', cleared_at: t(-9), cleared_by: 'TRS.ELOPEZ', created_by: 'ACC.BVILLA' },
    { receipt_no: 'OR-MNL-00000280', receipt_type: 'OR', client_code: 'C-00129', receipt_date: d(-30), amount: totBay, unapplied: 0, method: 'Bank transfer', reference: 'MBTC-33091', status: 'OR Issued', or_no: null, pr_no: null, check_no: null, check_bank: null, check_date: null, is_pdc: 0, deposit_status: 'Cleared', cleared_at: t(-29), cleared_by: 'TRS.ELOPEZ', created_by: 'ACC.BVILLA' },
  ]);
  ins('receipt_applications', [
    { receipt_no: 'OR-MNL-00000296', invoice_no: 'INV-MNL-00001095', amount: tot1095 },
    { receipt_no: 'OR-MNL-00000302', invoice_no: 'INV-MNL-00001098', amount: 20000 },
    { receipt_no: 'OR-CDO-00000011', invoice_no: 'INV-CDO-00000018', amount: totCdo18 },
    { receipt_no: 'OR-MNL-00000280', invoice_no: 'INV-MNL-00001050', amount: totBay },
  ]);
  invEvents.push({ invoice_no: 'INV-MNL-00001095', event_at: t(-20, '15:00'), event_by: 'ACC.BVILLA', action: 'Payment recorded', note: 'OR-MNL-00000296' });
  invEvents.push({ invoice_no: 'INV-MNL-00001098', event_at: t(-15, '15:00'), event_by: 'ACC.BVILLA', action: 'Payment recorded', note: 'OR-MNL-00000302 (partial)' });
  invEvents.push({ invoice_no: 'INV-MNL-00001098', event_at: t(-12, '11:00'), event_by: 'ACC.BVILLA', action: 'Credit memo applied', note: 'CM-000010' });
  ins('invoice_events', invEvents);

  ins('memos', [
    { memo_no: 'DM-000039', memo_type: 'Debit', client_code: 'C-00123', category: 'Rescue', reference_type: 'Rescue', reference_id: 'RSC-000041', reference_invoice_no: null, rescue_no: 'RSC-000041', jo_no: null, amount: rescueTotal, reason: 'Roadside rescue RSC-000041: travel 36 km + tire 11.00R20 + 10% service fee', status: 'Posted', applied_to: null, applied_at: null, workflow_id: null, source: 'Auto', created_by: 'system', created_at: t(-20, '10:30') },
    { memo_no: 'DM-000040', memo_type: 'Debit', client_code: 'C-00123', category: 'Repair', reference_type: 'Job Order', reference_id: 'JO-000121', reference_invoice_no: null, rescue_no: null, jo_no: 'JO-000121', amount: 2800, reason: 'Chargeable repair: LED tail lamp replaced (DW-CAV-2001)', status: 'Pending Approval', applied_to: null, applied_at: null, workflow_id: null, source: 'Auto', created_by: 'system', created_at: t(-3) },
    { memo_no: 'DM-000041', memo_type: 'Debit', client_code: 'C-00123', category: 'Park & Fix', reference_type: 'Park & Fix', reference_id: 'PF-000017', reference_invoice_no: null, rescue_no: null, jo_no: null, amount: 1500, reason: 'Park & Fix: brake adjustment at the MNL yard (DW-MNL-1001)', status: 'Posted', applied_to: null, applied_at: null, workflow_id: null, source: 'Manual', created_by: 'ACC.BVILLA', created_at: t(-7) },
    { memo_no: 'CM-000010', memo_type: 'Credit', client_code: 'C-00123', category: 'Billing adjustment', reference_type: 'Invoice', reference_id: 'INV-MNL-00001098', reference_invoice_no: 'INV-MNL-00001098', rescue_no: null, jo_no: null, amount: 1200, reason: 'Rate correction for DW-MNL-1004 (dispute DSP-000001)', status: 'Applied', applied_to: 'INV-MNL-00001098', applied_at: t(-12, '11:00'), workflow_id: null, source: 'Manual', created_by: 'ACC.BVILLA', created_at: t(-13) },
    { memo_no: 'DM-000036', memo_type: 'Debit', client_code: 'C-00124', category: 'Repair', reference_type: 'Job Order', reference_id: 'JO-000102', reference_invoice_no: null, rescue_no: null, jo_no: 'JO-000102', amount: 7350, reason: 'Chargeable repair: brake drum replaced (DW-CAV-2003)', status: 'Posted', applied_to: null, applied_at: null, workflow_id: null, source: 'Auto', created_by: 'system', created_at: t(-40) },
  ]);
  ins('payment_advices', [
    { advice_id: 'PA-000001', client_code: 'C-00123', invoice_no: 'INV-MNL-00001098', amount: 20000, paid_on: d(-16), method: 'Check', bank: 'BPI', reference: 'Check 004512', proof_file_id: F.pa1, remarks: 'Partial payment', status: 'Verified', receipt_no: 'OR-MNL-00000302', reject_reason: null, submitted_at: t(-20), submitted_by: 'U-000001' },
    { advice_id: 'PA-000002', client_code: 'C-00123', invoice_no: 'INV-MNL-00001101', amount: 10000, paid_on: d(-1), method: 'Bank transfer', bank: 'BDO', reference: 'BDO-990215', proof_file_id: F.pa2, remarks: null, status: 'Submitted', receipt_no: null, reject_reason: null, submitted_at: t(-1, '14:00'), submitted_by: 'U-000013' },
  ]);
  ins('invoice_disputes', [
    { dispute_id: 'DSP-000001', client_code: 'C-00123', invoice_no: 'INV-MNL-00001098', reason: 'Wrong rate', details: 'DW-MNL-1004 is on contract LTL-2025-0031 at ₱1,050/day, not ₱1,100.', amount_disputed: 1200, attachment_file_id: null, status: 'Resolved', resolution: 'Credit memo CM-000010 issued for the rate difference.', submitted_at: t(-28), submitted_by: 'U-000001' },
    { dispute_id: 'DSP-000002', client_code: 'C-00123', invoice_no: 'INV-MNL-00001102', reason: 'Damage not caused by us', details: 'The mud flap was already missing at Gate Out — see the attached photo.', amount_disputed: 1680, attachment_file_id: F.dsp2, status: 'Under review', resolution: null, submitted_at: t(-3), submitted_by: 'U-000001' },
  ]);
  ins('soa_sends', [
    { soa_no: raw("CONCAT('SOA-', YEAR(fn_manila_today()), '-00011')"), client_code: 'C-00123', period_from: d(-60), period_to: d(-31), channel: 'Email', sent_to: 'Your email + company billing email', tracking_no: null, sent_at: t(-30, '08:00'), sent_by: 'U-000001' },
  ]);

  // ── E-wallets, top-ups ──────────────────────────────────────────────────────────────────────────
  section('E-wallets, transactions (balance_after chained), top-up requests');
  ins('ewallets', [
    { client_code: 'C-00123', balance: bal, minimum_balance: 20000, opening_receipt_no: 'OR-MNL-00000290', treasury_confirmed_by: 'TRS.ELOPEZ', treasury_confirmed_at: t(-60, '11:00'), created_by: 'TRS.ELOPEZ', created_at: t(-60, '11:00') },
    { client_code: 'C-00124', balance: -2350, minimum_balance: 10000, opening_receipt_no: 'OR-CAV-00000120', treasury_confirmed_by: 'TRS.ELOPEZ', treasury_confirmed_at: t(-90), created_by: 'TRS.ELOPEZ', created_at: t(-90) },
    { client_code: 'C-00129', balance: 0, minimum_balance: 10000, opening_receipt_no: 'OR-MNL-00000150', treasury_confirmed_by: 'TRS.ELOPEZ', treasury_confirmed_at: t(-700), created_by: 'TRS.ELOPEZ', created_at: t(-700) },
    { client_code: 'C-00130', balance: 4200, minimum_balance: 15000, opening_receipt_no: 'OR-NVL-00000088', treasury_confirmed_by: 'TRS.ELOPEZ', treasury_confirmed_at: t(-58), created_by: 'TRS.ELOPEZ', created_at: t(-58) },
  ]);
  const tx = (id, client, at, type, cat, amt, after, rtype, rid, rcpt, by, reason) => ({ txn_id: id, client_code: client, txn_at: at, txn_type: type, category: cat, amount: amt, balance_after: after, reference_type: rtype, reference_id: rid, receipt_no: rcpt,
    treasury_ref: cat === 'Top-up' ? `TRS-${id.slice(-3)}` : null, posted_directly_by_treasury: 0, reverses_txn_id: null, reversed_by_txn_id: null, reason, posted_by: by });
  ins('ewallet_txns', [
    ...abcRows,
    tx('EWT-000080', 'C-00124', t(-90), 'Replenishment', 'Top-up', 5000, 5000, 'Top-up', 'TU-000010', 'OR-CAV-00000120', 'TRS.ELOPEZ', 'Opening deposit'),
    tx('EWT-000088', 'C-00124', t(-40), 'Deduction', 'Debit Memo', -7350, -2350, 'Debit Memo', 'DM-000036', null, 'ACC.BVILLA', 'Debit memo DM-000036 (brake drum)'),
    tx('EWT-000020', 'C-00129', t(-700), 'Replenishment', 'Top-up', 10000, 10000, 'Top-up', null, 'OR-MNL-00000150', 'TRS.ELOPEZ', 'Opening deposit'),
    tx('EWT-000095', 'C-00129', t(-45), 'Adjustment', 'Adjustment', -10000, 0, 'Adjustment', 'ADJ-000002', null, 'ACC.BVILLA', 'Balance refunded with the final statement'),
    tx('EWT-000090', 'C-00130', t(-58), 'Replenishment', 'Top-up', 15000, 15000, 'Top-up', null, 'OR-NVL-00000088', 'TRS.ELOPEZ', 'Opening deposit'),
    tx('EWT-000097', 'C-00130', t(-9), 'Deduction', 'Repair', -10800, 4200, 'Job Order', 'JO-000115', null, 'ACC.BVILLA', 'Two tires replaced (DW-NVL-4001)'),
  ]);
  const tu = (id, client, amt, date, method, bank, ref, fileId, status, by, o = {}) => ({
    topup_id: id, client_code: client, amount: amt, transfer_date: d(date), method, sending_bank: bank, payment_ref: ref, check_no: o.checkNo || null, check_date: o.checkDate || null, check_bank: o.checkBank || null,
    proof_file_id: fileId, remarks: o.remarks || null, resubmit_of: o.resubmitOf || null, status, submitted_at: t(date, '16:00'), submitted_by: by, bank_ref: o.bankRef || null, receipt_no: o.receipt || null,
    confirmed_by: ['Confirmed by Treasury', 'Posted'].includes(status) ? 'TRS.ELOPEZ' : null, confirmed_at: ['Confirmed by Treasury', 'Posted'].includes(status) ? t(date + 1, '10:00') : null,
    posted_by: status === 'Posted' ? 'TRS.ELOPEZ' : null, posted_at: status === 'Posted' ? t(date + 1, '11:00') : null, txn_id: o.txn || null,
    rejected_by: status === 'Rejected' ? 'TRS.ELOPEZ' : null, rejected_at: status === 'Rejected' ? t(date + 1, '10:00') : null, reject_reason: o.rejectReason || null,
  });
  ins('topup_requests', [
    tu('TU-000010', 'C-00124', 5000, -91, 'Bank transfer', 'Metrobank', 'MBTC-100233', F.tu10, 'Posted', 'U-000003', { bankRef: 'MB-55120', receipt: 'OR-CAV-00000120', txn: 'EWT-000080' }),
    tu('TU-000011', 'C-00123', 30000, -61, 'Bank transfer', 'BDO', 'BDO-445120', F.tu11, 'Posted', 'U-000001', { bankRef: 'BDO-STMT-0611', receipt: 'OR-MNL-00000290', txn: 'EWT-000101' }),
    tu('TU-000012', 'C-00123', 17000, -6, 'Over-the-counter deposit', 'BPI', 'BPI-DEP-7781', F.tu12, 'Posted', 'U-000013', { bankRef: 'BPI-STMT-1103', receipt: 'OR-MNL-00000307', txn: 'EWT-000104' }),
    tu('TU-000013', 'C-00123', 5000, -3, 'Bank transfer', 'BDO', 'BDO-44512O', F.tu13, 'Rejected', 'U-000001', { rejectReason: 'Reference not found on the bank statement — please check the reference number.' }),
    tu('TU-000014', 'C-00123', 5000, -1, 'Bank transfer', 'BDO', 'BDO-445129', F.tu14, 'Submitted', 'U-000001', { resubmitOf: 'TU-000013', remarks: 'Corrected reference' }),
    tu('TU-000015', 'C-00130', 2000, -2, 'Check', null, 'Check 778201', F.tu15, 'Confirmed by Treasury', 'U-000009', { checkNo: '778201', checkDate: d(-2), checkBank: 'Metrobank', bankRef: 'MB-CHK-778201' }),
  ]);

  // ── Cash bonds, withdrawals, workflows ──────────────────────────────────────────────────────────
  section('Workflows (approvals), cash bonds and withdrawals');
  ins('workflows', [
    { workflow_id: 'WF-00001', matrix_code: 'CASH_BOND_WITHDRAWAL', title: 'Cash bond withdrawal — ABC Logistics Corp.', subject_type: 'cashbond', subject_id: 'CB-000003', amount: 30000, branch_code: null, requested_by: 'U-000001', requested_at: t(-60), status: 'Approved', current_step: 3 },
    { workflow_id: 'WF-00002', matrix_code: 'CASH_BOND_WITHDRAWAL', title: 'Cash bond withdrawal (EARLY — exception) — ABC Logistics Corp.', subject_type: 'cashbond', subject_id: 'CB-000002', amount: 5000, branch_code: null, requested_by: 'U-000001', requested_at: t(-2), status: 'Pending', current_step: 1 },
    { workflow_id: 'WF-00003', matrix_code: 'EWA_EXTENSION', title: 'EWA extension — EU-000789', subject_type: 'ewa', subject_id: 'EU-000789', amount: null, branch_code: 'CAV', requested_by: 'U-000001', requested_at: ago(60), status: 'Pending', current_step: 1 },
  ]);
  ins('workflow_steps', [
    { workflow_id: 'WF-00001', step_no: 1, label: 'Credit & Collection review', roles_json: json(['CNC_OFFICER']), decision: 'Approved', decided_by: 'CNC.LCRUZ', decided_at: t(-59), due_at: null },
    { workflow_id: 'WF-00001', step_no: 2, label: 'Finance Manager approval', roles_json: json(['FINANCE_MANAGER']), decision: 'Approved', decided_by: 'FIN.GTAN', decided_at: t(-58), due_at: null },
    { workflow_id: 'WF-00001', step_no: 3, label: 'Accounting refund', roles_json: json(['ACCOUNTING']), decision: 'Approved', decided_by: 'ACC.BVILLA', decided_at: t(-55), due_at: null },
    { workflow_id: 'WF-00002', step_no: 1, label: 'Credit & Collection review', roles_json: json(['CNC_OFFICER']), decision: 'Pending', decided_by: null, decided_at: null, due_at: raw('(UTC_TIMESTAMP(3) + INTERVAL 46 HOUR)') },
    { workflow_id: 'WF-00002', step_no: 2, label: 'Finance Manager approval', roles_json: json(['FINANCE_MANAGER']), decision: 'Pending', decided_by: null, decided_at: null, due_at: null },
    { workflow_id: 'WF-00002', step_no: 3, label: 'Accounting refund', roles_json: json(['ACCOUNTING']), decision: 'Pending', decided_by: null, decided_at: null, due_at: null },
    { workflow_id: 'WF-00003', step_no: 1, label: 'Branch approval', roles_json: json(['BRANCH_GENERALIST']), decision: 'Pending', decided_by: null, decided_at: null, due_at: ahead(4 * 60) },
  ]);
  ins('workflow_signatures', [
    { workflow_id: 'WF-00001', step_no: 1, user_id: 'CNC.LCRUZ', role_code: 'CNC_OFFICER', decision: 'Approved', comment: 'No open balance on LTL-2024-0012', signed_at: t(-59) },
    { workflow_id: 'WF-00001', step_no: 2, user_id: 'FIN.GTAN', role_code: 'FINANCE_MANAGER', decision: 'Approved', comment: null, signed_at: t(-58) },
    { workflow_id: 'WF-00001', step_no: 3, user_id: 'ACC.BVILLA', role_code: 'ACCOUNTING', decision: 'Approved', comment: 'Refunded by bank transfer', signed_at: t(-55) },
  ]);
  ins('cash_bonds', [
    { bond_id: 'CB-000001', client_code: 'C-00123', contract_no: 'LTL-2025-0045', amount: 60000, date_received: d(-352), receipt_ref: 'OR-MNL-00000201', payment_method: 'Check', received_by: 'TRS.ELOPEZ', status: 'Held', outcome_kind: null, outcome_at: null, outcome_amount: null, outcome_reference: null, outcome_note: null, outcome_to_contract: null, notes: null },
    { bond_id: 'CB-000002', client_code: 'C-00123', contract_no: 'LTL-2025-0031', amount: 20000, date_received: d(-332), receipt_ref: 'OR-MNL-00000198', payment_method: 'Bank transfer', received_by: 'TRS.ELOPEZ', status: 'Withdrawal Pending', outcome_kind: null, outcome_at: null, outcome_amount: null, outcome_reference: null, outcome_note: null, outcome_to_contract: null, notes: null },
    { bond_id: 'CB-000003', client_code: 'C-00123', contract_no: 'LTL-2024-0012', amount: 30000, date_received: d(-802), receipt_ref: 'OR-MNL-00000044', payment_method: 'Check', received_by: 'TRS.ELOPEZ', status: 'Refunded', outcome_kind: 'Refunded', outcome_at: t(-55), outcome_amount: 30000, outcome_reference: 'CBW-000001', outcome_note: 'Refunded after contract end', outcome_to_contract: null, notes: null },
    { bond_id: 'CB-000004', client_code: 'C-00124', contract_no: 'LTL-2025-0050', amount: 25000, date_received: d(-302), receipt_ref: 'OR-CAV-00000101', payment_method: 'Check', received_by: 'TRS.ELOPEZ', status: 'Held', outcome_kind: null, outcome_at: null, outcome_amount: null, outcome_reference: null, outcome_note: null, outcome_to_contract: null, notes: null },
    { bond_id: 'CB-000005', client_code: 'C-00125', contract_no: 'QLP-2026-0003', amount: 15000, date_received: d(-122), receipt_ref: 'OR-CDO-00000005', payment_method: 'Bank transfer', received_by: 'TRS.ELOPEZ', status: 'Held', outcome_kind: null, outcome_at: null, outcome_amount: null, outcome_reference: null, outcome_note: null, outcome_to_contract: null, notes: null },
    { bond_id: 'CB-000006', client_code: 'C-00129', contract_no: 'LTL-2024-0020', amount: 25000, date_received: d(-772), receipt_ref: 'OR-MNL-00000038', payment_method: 'Check', received_by: 'TRS.ELOPEZ', status: 'Held', outcome_kind: null, outcome_at: null, outcome_amount: null, outcome_reference: null, outcome_note: null, outcome_to_contract: null, notes: 'Contract ended — refundable on request' },
    { bond_id: 'CB-000007', client_code: 'C-00130', contract_no: 'LTL-2026-0002', amount: 15000, date_received: d(-62), receipt_ref: 'OR-NVL-00000087', payment_method: 'Bank transfer', received_by: 'TRS.ELOPEZ', status: 'Held', outcome_kind: null, outcome_at: null, outcome_amount: null, outcome_reference: null, outcome_note: null, outcome_to_contract: null, notes: null },
  ]);
  ins('cash_bond_withdrawals', [
    { withdrawal_id: 'CBW-000001', bond_id: 'CB-000003', amount: 30000, reason: 'Contract LTL-2024-0012 ended; replaced by LTL-2025-0045.', refundable_at_request: 30000, early_exception: 0, workflow_id: 'WF-00001', status: 'Refunded', requested_at: t(-60), requested_by: 'U-000001', rejected_at: null, reject_reason: null, refund_method: 'Bank transfer', refund_date: d(-55), refund_reference: 'BDO-RF-22019', refund_by: 'ACC.BVILLA' },
    { withdrawal_id: 'CBW-000002', bond_id: 'CB-000002', amount: 5000, reason: 'Fleet reduced from 4 to 1 unit on LTL-2025-0031; requesting partial release.', refundable_at_request: 5000, early_exception: 1, workflow_id: 'WF-00002', status: 'Pending', requested_at: t(-2), requested_by: 'U-000001', rejected_at: null, reject_reason: null, refund_method: null, refund_date: null, refund_reference: null, refund_by: null },
  ]);
  const sources = json({ invoices: [], pendingMemos: [], unsettledMemos: [] });
  ins('cash_bond_withdrawal_breakdowns', [
    { withdrawal_id: 'CBW-000001', stage: 'Request', computed_at: t(-60), bond: 30000, unpaid: 0, negative_wallet: 0, pending_dm: 0, posted_unsettled_dm: 0, deductions: 0, refundable: 30000, sources_json: sources },
    { withdrawal_id: 'CBW-000001', stage: 'Recheck', computed_at: t(-55), bond: 30000, unpaid: 0, negative_wallet: 0, pending_dm: 0, posted_unsettled_dm: 0, deductions: 0, refundable: 30000, sources_json: sources },
    { withdrawal_id: 'CBW-000002', stage: 'Request', computed_at: t(-2), bond: 20000, unpaid: 0, negative_wallet: 0, pending_dm: 2800, posted_unsettled_dm: 1500, deductions: 4300, refundable: 15700, sources_json: json({ invoices: [], pendingMemos: [{ memoNo: 'DM-000040', amount: 2800 }], unsettledMemos: [{ memoNo: 'DM-000041', amount: 1500 }] }) },
  ]);

  // ── Vendor portal: POs, receiving, vendor invoices ──────────────────────────────────────────────
  section('Purchase orders, receiving reports, vendor invoices (Tire Pro Supply)');
  ins('purchase_orders', [
    { po_no: 'PO-000154', pr_no: 'PR-000301', vendor_id: 'V-001', entity_code: 'DBL', terms: '30 days', delivery_date: d(-20), status: 'Partially Received', workflow_id: null, created_at: t(-35) },
    { po_no: 'PO-000158', pr_no: 'PR-000309', vendor_id: 'V-001', entity_code: 'DBL', terms: '30 days', delivery_date: d(-30), status: 'Received', workflow_id: null, created_at: t(-45) },
    { po_no: 'PO-000161', pr_no: 'PR-000315', vendor_id: 'V-001', entity_code: 'NAK', terms: '30 days', delivery_date: d(10), status: 'Issued', workflow_id: null, created_at: t(-4) },
    { po_no: 'PO-000162', pr_no: 'PR-000316', vendor_id: 'V-001', entity_code: 'DBL', terms: '30 days', delivery_date: d(14), status: 'For Approval', workflow_id: null, created_at: t(-1) },
  ]);
  ins('po_lines', [
    { po_no: 'PO-000154', part_code: 'TIRE-1100R20', description: 'Tire 11.00R20 (radial)', qty: 20, unit_price: 14500, qty_received: 12 },
    { po_no: 'PO-000154', part_code: 'TIRE-1000R20', description: 'Tire 10.00R20 (bias)', qty: 10, unit_price: 11800, qty_received: 10 },
    { po_no: 'PO-000158', part_code: 'TIRE-1100R20', description: 'Tire 11.00R20 (radial)', qty: 8, unit_price: 14500, qty_received: 8 },
    { po_no: 'PO-000161', part_code: 'TIRE-1100R20', description: 'Tire 11.00R20 (radial)', qty: 16, unit_price: 14300, qty_received: 0 },
    { po_no: 'PO-000162', part_code: 'TIRE-1000R20', description: 'Tire 10.00R20 (bias)', qty: 6, unit_price: 11800, qty_received: 0 },
  ]);
  ins('receiving_reports', [
    { rr_no: 'RR-000088', po_no: 'PO-000158', received_date: d(-30), received_by: 'BG.MNL.PDIAZ', warehouse_code: 'MNL-WH', has_discrepancy: 0, condition_notes: null },
    { rr_no: 'RR-000093', po_no: 'PO-000154', received_date: d(-18), received_by: 'BG.MNL.PDIAZ', warehouse_code: 'MNL-WH', has_discrepancy: 0, condition_notes: null },
    { rr_no: 'RR-000097', po_no: 'PO-000154', received_date: d(-8), received_by: 'BG.MNL.PDIAZ', warehouse_code: 'MNL-WH', has_discrepancy: 1, condition_notes: '1 tire rejected (sidewall bulge), replacement to follow' },
  ]);
  ins('rr_lines', [
    { rr_no: 'RR-000088', part_code: 'TIRE-1100R20', qty_received: 8, qty_rejected: 0, item_condition: 'Good' },
    { rr_no: 'RR-000093', part_code: 'TIRE-1100R20', qty_received: 8, qty_rejected: 0, item_condition: 'Good' },
    { rr_no: 'RR-000093', part_code: 'TIRE-1000R20', qty_received: 10, qty_rejected: 0, item_condition: 'Good' },
    { rr_no: 'RR-000097', part_code: 'TIRE-1100R20', qty_received: 4, qty_rejected: 1, item_condition: 'Good (1 rejected)' },
  ]);
  ins('vendor_invoices', [
    { vendor_invoice_id: 'VI-000001', vendor_id: 'V-001', po_no: 'PO-000158', rr_no: 'RR-000088', invoice_no: 'SI-20871', invoice_date: d(-26), amount: 8 * 14500, file_id: F.vi1, status: 'Paid', submitted_via: 'Portal', submitted_at: t(-25), reject_reason: null, resubmit_of: null },
    { vendor_invoice_id: 'VI-000002', vendor_id: 'V-001', po_no: 'PO-000154', rr_no: 'RR-000093', invoice_no: 'SI-20915', invoice_date: d(-10), amount: 20 * 14500, file_id: F.vi2, status: 'Rejected', submitted_via: 'Portal', submitted_at: t(-9), reject_reason: 'Billed 20 tires; only 8 were received at that time. Please bill received quantities only.', resubmit_of: null },
    { vendor_invoice_id: 'VI-000003', vendor_id: 'V-001', po_no: 'PO-000154', rr_no: 'RR-000093', invoice_no: 'SI-20915-R', invoice_date: d(-7), amount: 8 * 14500 + 10 * 11800, file_id: F.vi3, status: 'Under Review', submitted_via: 'Portal', submitted_at: t(-6), reject_reason: null, resubmit_of: 'VI-000002' },
  ]);
  ins('vendor_invoice_lines', [
    { vendor_invoice_id: 'VI-000001', part_code: 'TIRE-1100R20', qty: 8, unit_price: 14500 },
    { vendor_invoice_id: 'VI-000002', part_code: 'TIRE-1100R20', qty: 20, unit_price: 14500 },
    { vendor_invoice_id: 'VI-000003', part_code: 'TIRE-1100R20', qty: 8, unit_price: 14500 },
    { vendor_invoice_id: 'VI-000003', part_code: 'TIRE-1000R20', qty: 10, unit_price: 11800 },
  ]);
  ins('vendor_invoice_history', [
    ['VI-000001', 'Submitted', t(-25), 'U-000010', null], ['VI-000001', 'Under Review', t(-24), 'APS.KTAN', null], ['VI-000001', 'Approved', t(-22), 'APS.KTAN', 'Matched to RR-000088'], ['VI-000001', 'Paid', t(-5), 'ACC.BVILLA', 'Paid by bank transfer'],
    ['VI-000002', 'Submitted', t(-9), 'U-000010', null], ['VI-000002', 'Rejected', t(-8), 'APS.KTAN', 'Billed quantity exceeds the received quantity'],
    ['VI-000003', 'Submitted', t(-6), 'U-000010', 'Resubmission of VI-000002'], ['VI-000003', 'Under Review', t(-5), 'APS.KTAN', null],
  ].map(([id, s, at, by, note]) => ({ vendor_invoice_id: id, status: s, status_at: at, status_by: by, note })));

  // ── Notifications, feedback, outbox (delivery log) ──────────────────────────────────────────────
  section('In-app notifications, client feedback, email delivery log (all Sent — nothing is queued for the worker)');
  const note = (user, ev, title, body, link, read, at) => ({ user_id: user, event_type: ev, title, body, link, is_read: read ? 1 : 0, requires_ack: 0, ack_at: null, created_at: at });
  ins('notifications', [
    note('U-000001', 'ewa.created', 'EWA EU-000790 created', 'Pickup at Manila Yard: 1 × 20ft chassis, 1 × 40ft chassis. Valid for 24 hours.', '/client/ewa', 0, ago(118)),
    note('U-000001', 'rescue.dispatched', 'Rescue RSC-000042: crew on the way', 'Team Bravo is on the way to C-5 Road southbound. Estimated arrival in about 25 minutes.', '/client/rescue', 0, ago(70)),
    note('U-000001', 'topup.rejected', 'Top-up TU-000013 was not accepted', 'The payment reference was not found on the bank statement. Submit it again with the correct reference.', '/client/ewallet', 1, t(-2, '10:00')),
    note('U-000001', 'invoice.issued', 'New invoice INV-MNL-00001104', 'Please acknowledge the invoice — the credit term starts on acknowledgment.', '/client/invoices', 0, t(-4, '17:05')),
    note('U-000001', 'contract.renewal_notice', 'Contract LTL-2025-0031 ends in 2 months', 'Request a renewal from the Contracts page or talk to your Account Executive.', '/client/contracts', 1, t(-26, '00:10')),
    note('U-000001', 'client.return_request', 'Return RTN-000002 requested', 'DW-LAG-3001 will be collected at Laguna Depot. The branch confirms the schedule.', '/client', 1, t(-1, '16:00')),
    note('U-000003', 'client.hold', 'Your account is on hold', 'An invoice is more than 30 days past due. New EWAs and rescue requests are blocked until it is settled.', '/client/invoices', 0, t(-12, '01:00')),
    note('U-000009', 'ewallet.below_minimum', 'E-wallet below the contract minimum', 'Your balance is below ₱15,000. Please top up so rescue and repair charges are covered.', '/client/ewallet', 0, t(-9)),
  ]);
  ins('client_feedback', [
    { feedback_id: 'FB-00001', client_code: 'C-00123', category: 'Rating', topic: 'Rescue', rating: 5, subject: '5-star rating — Rescue', message: 'Fast response on SLEX, thank you Team Alpha!', reference: 'RSC-000041', status: 'Acknowledged', submitted_at: t(-19), submitted_by: 'U-000001' },
    { feedback_id: 'FB-00002', client_code: 'C-00123', category: 'Billing', topic: null, rating: null, subject: 'Weekly invoice cut-off', message: 'Can the weekly invoice include the Thursday returns of the same week?', reference: 'INV-MNL-00001101', status: 'Submitted', submitted_at: t(-7), submitted_by: 'U-000013' },
  ]);
  const ob = []; let obN = 0;
  const msg = (type, id, ev, channel, audience, label, userId, name, to, subject, at, o = {}) => {
    obN++;
    ob.push({ entity_type: type, entity_id: id, event_type: ev, channel, audience, recipient_label: label, recipient_user_id: userId, recipient_name: name ? enc(name) : null, to_address: enc(to), subject, body: null,
      template_data_json: null, is_resend: o.resend ? 1 : 0, status: o.status || 'Sent', attempts: 1, next_attempt_at: at, provider_message_id: o.status === 'Failed' ? null : `sample-${String(obN).padStart(4, '0')}`,
      last_error: o.error || null, claim_token: null, claimed_at: null, queued_at: at, sent_at: o.status === 'Failed' ? null : at });
  };
  msg('ewa', 'EU-000790', 'ewa.created', 'Email', 'Client', 'You (EWA requester)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'EWA EU-000790 — Manila Yard', ago(119));
  msg('ewa', 'EU-000790', 'ewa.created', 'Email', 'Delbros', 'Branch Generalist, MNL (prepares the release)', 'BG.MNL.PDIAZ', 'Paolo Diaz', staffEmail['BG.MNL.PDIAZ'], 'EWA EU-000790 — Manila Yard', ago(119));
  msg('ewa', 'EU-000790', 'ewa.created', 'Email', 'Delbros', 'Account Executive', 'AE.JREYES', 'Juan Reyes', staffEmail['AE.JREYES'], 'EWA EU-000790 — Manila Yard', ago(119));
  msg('ewa', 'EU-000789', 'ewa.created', 'Email', 'Client', 'You (EWA requester)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'EWA EU-000789 — Cavite Depot', ago(20 * 60 - 1));
  msg('ewa', 'EU-000789', 'ewa.created', 'Email', 'Delbros', 'Branch Generalist, CAV (prepares the release)', 'BG.CAV.RGARCIA', 'Rhea Garcia', staffEmail['BG.CAV.RGARCIA'], 'EWA EU-000789 — Cavite Depot', ago(20 * 60 - 1));
  msg('ewa', 'EU-000789', 'ewa.extension_requested', 'Email', 'Delbros', 'Branch Generalist, CAV (approves the extension)', 'BG.CAV.RGARCIA', 'Rhea Garcia', staffEmail['BG.CAV.RGARCIA'], 'Extension requested — EU-000789', ago(59));
  msg('ewa', 'EU-000781', 'ewa.created', 'Email', 'Client', 'You (EWA requester)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'EWA EU-000781 — Manila Yard', t(-41, '15:00'));
  msg('ewa', 'EU-000781', 'ewa.created', 'Email', 'Client', 'Trucker (copy to the driver\'s company)', null, null, 'dispatch@abctrucking.ph', 'EWA EU-000781 — Manila Yard', t(-41, '15:00'), { status: 'Failed', error: 'MessageRejected: Email address is not verified (sample)' });
  msg('rescue', 'RSC-000042', 'rescue.requested', 'Email', 'Delbros', 'Rescue Coordinator (dispatches the crew)', 'RSC.DMORALES', 'Dennis Morales', staffEmail['RSC.DMORALES'], 'URGENT rescue RSC-000042 — DW-MNL-1003', ago(99));
  msg('rescue', 'RSC-000042', 'rescue.requested', 'Email', 'Client', 'You (confirmation)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'Rescue RSC-000042 received', ago(99));
  msg('rescue', 'RSC-000041', 'rescue.completed', 'Email', 'Client', 'You (completion and charges)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'Rescue RSC-000041 completed', t(-20, '10:10'));
  msg('topup', 'TU-000014', 'topup.submitted', 'Email', 'Delbros', 'Treasury (confirms the deposit)', 'TRS.ELOPEZ', 'Elena Lopez', staffEmail['TRS.ELOPEZ'], 'Top-up TU-000014 to confirm', t(-1, '16:01'));
  msg('topup', 'TU-000014', 'topup.submitted', 'Email', 'Client', 'You (confirmation)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'Top-up TU-000014 received', t(-1, '16:01'));
  msg('topup', 'TU-000013', 'topup.rejected', 'Email', 'Client', 'You (decision)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'Top-up TU-000013 not accepted', t(-2, '10:00'));
  msg('return_request', 'RTN-000002', 'client.return_request', 'Email', 'Delbros', 'Branch Generalist, LAG (schedules the Gate In)', 'BG.LAG.NVILLAR', 'Noel Villar', staffEmail['BG.LAG.NVILLAR'], 'Return RTN-000002 — DW-LAG-3001', t(-1, '16:00'));
  msg('return_request', 'RTN-000002', 'client.return_request', 'Email', 'Delbros', 'Account Executive', 'AE.JREYES', 'Juan Reyes', staffEmail['AE.JREYES'], 'Return RTN-000002 — DW-LAG-3001', t(-1, '16:00'));
  msg('return_request', 'RTN-000002', 'client.return_request', 'Email', 'Client', 'You (confirmation)', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'Return RTN-000002 received', t(-1, '16:00'));
  msg('payment_advice', 'PA-000002', 'payment_advice.submitted', 'Email', 'Delbros', 'Accounting (records the receipt)', 'ACC.BVILLA', 'Bea Villa', staffEmail['ACC.BVILLA'], 'Proof of payment PA-000002 — INV-MNL-00001101', t(-1, '14:00'));
  msg('invoice_dispute', 'DSP-000002', 'invoice.disputed', 'Email', 'Delbros', 'Account Executive', 'AE.JREYES', 'Juan Reyes', staffEmail['AE.JREYES'], 'Dispute DSP-000002 — INV-MNL-00001102', t(-3));
  msg('soa', 'SOA-placeholder', 'soa.emailed', 'Email', 'Client', 'Your email', 'U-000001', 'Ana Reyes', 'client@abclogistics.ph', 'Statement of account', t(-30, '08:00'));
  msg('access_request', 'PAR-000004', 'access.review', 'Email', 'Delbros', 'Your Account Executive', 'AE.JREYES', 'Juan Reyes', staffEmail['AE.JREYES'], 'Approve portal access — Islandlink Cargo Services (PAR-000004)', t(-2, '09:01'));
  msg('access_request', 'PAR-000004', 'access.submitted', 'Email', 'Applicant', 'You (applicant)', 'U-000006', 'Tess Ramirez', 'tess@islandlink.ph', 'We received your portal access request (PAR-000004)', t(-2, '09:01'));
  msg('vendor_invoice', 'VI-000003', 'vendor_invoice.submitted', 'Email', 'Delbros', 'APS Officer (reviews supplier invoices)', 'APS.KTAN', 'Kevin Tan', staffEmail['APS.KTAN'], 'Supplier invoice VI-000003 — PO-000154', t(-6));
  // SOA entity id must be a plain value: use the soa_no expression
  ob.find((m) => m.entity_type === 'soa').entity_id = raw("CONCAT('SOA-', YEAR(fn_manila_today()), '-00011')");
  ins('message_outbox', ob);

  // ── Number sequences: next numbers continue after the sample ones ──────────────────────────────
  section('Number sequences — next documents created through the portal continue after the sample numbers');
  const seq = [['CBW', 2], ['CLIENT', 131], ['CRQ', 2], ['DSP', 2], ['EU', 790], ['FB', 2], ['PA', 2], ['PAR', 4], ['RSC', 43], ['RTN', 2], ['TU', 15], ['USER', 13], ['VENDOR', 3], ['VI', 3], ['WF', 3]];
  out.push(`INSERT INTO number_sequences (series_key, \`last_value\`) VALUES\n${seq.map(([k, v]) => ` (${lit(k)}, ${v})`).join(',\n')},\n (CONCAT('SOA:', YEAR(fn_manila_today())), 11)\n ON DUPLICATE KEY UPDATE \`last_value\` = GREATEST(\`last_value\`, VALUES(\`last_value\`));`);
  counts.number_sequences = seq.length + 1;

  // ── Write ───────────────────────────────────────────────────────────────────────────────────────
  const header = `-- =====================================================================================================
-- 30_sample_data.sql : DUMMY data for development / UAT — NEVER run against production.
-- GENERATED by database/sample/generate-sample-data.js — do not edit by hand.
--
-- TIED TO THE KEYS IN App/.env: personal data is AES-256-GCM ciphertext (PII_ENCRYPTION_KEY) and the *_hash
-- columns are HMAC blind indexes (PII_HASH_KEY). If the keys change, regenerate:  npm run sample-data
--
-- Run after 01 … 11 and 20_seed_reference.sql, on an EMPTY database (it inserts fixed IDs). Dates are relative
-- to the day this script is executed (Manila calendar). Demo logins: see database/README.md (password ${DEMO_PASSWORD}).
-- Not included: audit_log rows (the hash chain starts at the genesis row), sessions, OTP challenges, reset links.
-- =====================================================================================================
USE delbros_portal;
SET NAMES utf8mb4;
SET time_zone = '+00:00';
START TRANSACTION;
`;
  fs.writeFileSync(OUT, `${header}${out.join('\n')}\n\nCOMMIT;\n`);
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  console.log(`Wrote ${path.relative(process.cwd(), OUT)} — ${total} rows in ${Object.keys(counts).length} tables`);
  for (const [k, v] of Object.entries(counts)) console.log(`  ${k.padEnd(34)} ${v}`);
  console.log(`  e-wallet C-00123 balance ${bal} (minimum 20000) · rescue RSC-000041 total ${rescueTotal} · approval token for PAR-000004: ${APPROVAL_TOKEN}`);
}

main().then(() => {
  // Static check of the generated file against 01_schema.sql (+ seed): tables, columns, ENUM values, NOT NULL, PK, FK.
  const r = require('./check-columns').check();
  if (!r.ok) process.exitCode = 1;
}).catch((e) => { console.error(e); process.exitCode = 1; });
