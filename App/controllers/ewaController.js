// EWA: options, list, details, create, cancel, extension, resend email.
// PDPA: driver name and licence are validated here, then encrypted before they reach the database.
const crypto = require('./cryptoController');
const ewaModel = require('../models/ewaModel');
const { ApiError, asyncHandler, respond } = require('./errorController');
const { RE, str, opt, date, paging, source } = require('./helpers');
const log = require('../config/logger').getLogger('ewa'); // internal ids only — no personal data

const uid = (req) => req.session.userId;

// DATETIME values inside JSON_OBJECT / JSON_ARRAYAGG come back as "2026-11-19 05:01:48.669000" (UTC, no zone).
// Browsers would read that as local time, so every such string becomes ISO-8601 UTC ("2026-11-19T05:01:48.669Z").
const SQL_DT = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?$/;
function isoDeep(v) {
  if (typeof v === 'string' && SQL_DT.test(v)) { const [d, t] = v.split(' '); const [hms, frac = ''] = t.split('.'); return `${d}T${hms}.${(frac + '000').slice(0, 3)}Z`; }
  if (Array.isArray(v)) return v.map(isoDeep);
  if (v && typeof v === 'object' && !(v instanceof Date) && !Buffer.isBuffer(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, isoDeep(x)]));
  return v;
}
const bool = (v) => v === true || v === 1 || v === '1';
const byKey = (k) => (a, b) => String(a[k] ?? '').localeCompare(String(b[k] ?? ''));
/** Outbox rows → delivery log entries. 'Sending' (claimed by the worker) shows as Queued; recipientName stays ciphertext until respond(). */
const deliveryOf = (rows) => (rows || []).map((d) => ({ ...d, status: d.status === 'Sending' ? 'Queued' : d.status, resend: bool(d.resend) }))
  .sort((a, b) => (a.id ?? 0) - (b.id ?? 0) || byKey('at')(a, b));

/** One sp_ewa_list row → the shape the portal EWA list, detail dialog, print view and confirmation read. */
function ewaRow(r) {
  const e = isoDeep(r);
  return {
    ...e,
    units: (e.units || []).map((u) => ({ equipmentType: u.equipmentType, qty: Number(u.qty), usedChassis: u.usedChassis || [] })),
    gatePasses: (e.gatePasses || []).sort(byKey('at')),
    extensions: (e.extensions || []).sort((a, b) => (a.id ?? 0) - (b.id ?? 0)),
    extension: e.extension ? { ...e.extension, approvals: (e.extension.approvals || []).sort(byKey('at')) } : null,
    delivery: deliveryOf(e.delivery),
  };
}

const details = (sets) => {
  const [header, lines, releases, extensions, emailLog, history] = sets.map(isoDeep);
  return { ...header[0], canCancel: bool(header[0].canCancel), canExtend: bool(header[0].canExtend), lines, releases, extensions, emailLog: deliveryOf(emailLog), history };
};

/** The list row for one EWA (same shape as GET /portal/ewa items). */
async function oneRow(userId, euNo) {
  const { sets } = await ewaModel.list(userId, { q: euNo, qLicenceHash: null, status: null, from: null, to: null, page: 1, pageSize: 5 });
  const row = (sets[0] || []).find((x) => x.euNo === euNo);
  if (!row) throw new ApiError('NOT_FOUND', 'EWA not found.');
  return ewaRow(row);
}

const options = asyncHandler(async (req, res) => {
  const [header, contracts, branches, availability, drivers, trucks] = (await ewaModel.options(uid(req))).sets.map(isoDeep);
  const avail = {};
  for (const b of branches) avail[b.code] ??= {};
  for (const a of availability) (avail[a.branchCode] ??= {})[a.equipmentType] = Number(a.available);
  const h = header[0] || {};
  respond(res, {
    ...h, blocked: h.blocked || null, walletNotice: h.walletNotice || undefined, validityHours: Number(h.validityHours ?? 24),
    // An AE row with no user gives {"name":null,…}; the screen expects null then.
    accountExecutive: h.accountExecutive && (h.accountExecutive.name || h.accountExecutive.email) ? h.accountExecutive : null,
    // The screen reads entitlement.{types, unitQty, onHire, pending, contractRemaining} (same as the mock's ewaEntitlement()).
    contracts: contracts.map(({ unitQty, onHire, pending, contractRemaining, types, ...c }) => ({
      ...c, entitlement: { unitQty: Number(unitQty), onHire: Number(onHire), pending: Number(pending), contractRemaining: Number(contractRemaining),
        types: (types || []).map((t) => ({ ...t, onHire: Number(t.onHire), pending: Number(t.pending), remaining: Number(t.remaining) })) } })),
    branches, availability: avail, drivers, trucks,
  });
});

const list = asyncHandler(async (req, res) => {
  const q = req.query; const pg = paging(q);
  const search = opt(q.q);
  const { sets } = await ewaModel.list(uid(req), { q: search, qLicenceHash: search ? crypto.blindIndex('licence', search) : null, status: opt(q.status),
    from: date(q.from), to: date(q.to), page: pg.page, pageSize: pg.pageSize || 8 });
  respond(res, { items: (sets[0] || []).map(ewaRow), total: Number(sets[1][0].total), page: pg.page, pageSize: pg.pageSize || 8 });
});

const get = asyncHandler(async (req, res) => respond(res, details((await ewaModel.get(uid(req), str(req.params.euNo))).sets)));

// POST /portal/ewa
const create = asyncHandler(async (req, res) => {
  const b = req.body;
  const e = {
    contractNo: str(b.contractNo), branchCode: str(b.branchCode), trucker: str(b.trucker),
    truckPlateNo: str(b.truckPlateNo).toUpperCase().replace(/\s+/g, ' '), truckOrcr: opt(b.truckOrcr),
    driverName: str(b.driverName), driverLicenseNo: str(b.driverLicenseNo).toUpperCase(),
    expectedPickupAt: b.expectedPickupAt ? new Date(b.expectedPickupAt) : null, remarks: opt(b.remarks),
    units: Array.isArray(b.units) ? b.units.map((u) => ({ equipmentType: str(u.equipmentType), qty: Number(u.qty) })) : [],
  };
  // "Missing driver/truck info" and LTO formats (the database cannot check encrypted values).
  const blank = Object.fromEntries([['trucker', e.trucker], ['truckPlateNo', e.truckPlateNo], ['driverName', e.driverName], ['driverLicenseNo', e.driverLicenseNo]]
    .filter(([, v]) => !v).map(([k]) => [k, 'Required']));
  if (Object.keys(blank).length) throw new ApiError('MISSING_DRIVER_TRUCK_INFO', 'Missing driver/truck info: enter the trucker, truck plate no., driver name and driver license no.', blank);
  const fmt = {};
  if (!RE.plate.test(e.truckPlateNo)) fmt.truckPlateNo = 'Use the LTO format, e.g. NAB 5678';
  if (!RE.licence.test(e.driverLicenseNo)) fmt.driverLicenseNo = 'Use the LTO format, e.g. N01-23-456789';
  if (e.expectedPickupAt && Number.isNaN(e.expectedPickupAt.getTime())) fmt.expectedPickupAt = 'Not a valid date and time';
  if (Object.keys(fmt).length) throw new ApiError('VALIDATION_FAILED', 'Check the truck plate and driver license format.', fmt);

  const { out } = await ewaModel.create(uid(req), {
    ...e, driverLicenseHash: crypto.blindIndex('licence', e.driverLicenseNo),
    driverName: crypto.encrypt(e.driverName), driverLicenseNo: crypto.encrypt(e.driverLicenseNo),
  }, source(req));
  log.info(`EWA ${out.o_eu_no} created: contract ${e.contractNo}, branch ${e.branchCode}, ${e.units.reduce((a, u) => a + u.qty, 0)} unit(s) user=${uid(req)}`);
  // The new EWA in the list shape (the confirmation shows the same details and email log as the list).
  respond(res, await oneRow(uid(req), out.o_eu_no), 201);
});

const cancel = asyncHandler(async (req, res) => {
  const euNo = str(req.params.euNo);
  await ewaModel.cancel(uid(req), euNo, str(req.body.reason), source(req));
  log.info(`EWA ${euNo} cancelled by the client user=${uid(req)}`);
  respond(res, await oneRow(uid(req), euNo));
});

const extension = asyncHandler(async (req, res) => {
  await ewaModel.extension(uid(req), str(req.params.euNo), str(req.body.reason), source(req));
  log.info(`EWA ${str(req.params.euNo)} extension requested user=${uid(req)}`);
  res.status(204).end();
});

const resendEmail = asyncHandler(async (req, res) => {
  const { sets } = await ewaModel.resendEmail(uid(req), str(req.params.euNo), source(req));
  const items = deliveryOf(isoDeep(sets[0] || []));
  log.info(`EWA ${str(req.params.euNo)} email queued again for ${items.length} recipient(s) user=${uid(req)}`);
  respond(res, { items });
});

module.exports = { options, list, get, create, cancel, extension, resendEmail, isoDeep, bool };
