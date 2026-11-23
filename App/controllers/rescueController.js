// Rescue: options, list, details, create, cancel.
// PDPA: the scene contact name and phone are validated here, then encrypted before they reach the database.
const crypto = require('./cryptoController');
const rescueModel = require('../models/rescueModel');
const { ApiError, asyncHandler, respond } = require('./errorController');
const { isoDeep, bool } = require('./ewaController');
const { RE, str, opt, num, check, paging, source } = require('./helpers');
const log = require('../config/logger').getLogger('rescue'); // internal ids only — no personal data

const uid = (req) => req.session.userId;
const numOrNull = (v) => (v === null || v === undefined ? null : Number(v));

/** One sp_rescue_list row → the shape the portal rescue list, detail dialog and confirmation read. */
function rescueRow(r) {
  const x = isoDeep(r);
  const timeline = (x.timeline || []).sort((a, b) => (a.id ?? 0) - (b.id ?? 0)).map(({ id, ...t }) => t);
  return {
    ...x,
    urgent: bool(x.urgent), isOpen: bool(x.isOpen), canCancel: bool(x.canCancel), chargeable: bool(x.chargeable),
    lat: numOrNull(x.lat), lng: numOrNull(x.lng), oneWayKm: numOrNull(x.oneWayKm),
    serviceChargePct: Number(x.serviceChargePct ?? 0.1), vatPct: Number(x.vatPct ?? 0.12),
    timeline, statusLog: timeline,
    costLines: (x.costLines || []).sort((a, b) => a.lineNo - b.lineNo).map(({ lineNo, ...l }) => ({ ...l, qty: Number(l.qty), unitPrice: Number(l.unitPrice) })),
    photos: x.photos || [],
    notified: (x.notified || []).sort((a, b) => (a.id ?? 0) - (b.id ?? 0)).map((d) => ({ ...d, status: d.status === 'Sending' ? 'Queued' : d.status })),
    hire: x.hire && x.hire.gatePassNo ? x.hire : null,
  };
}

const details = (sets) => {
  const [header, timeline, costLines, photos, notified] = sets.map(isoDeep);
  return { ...header[0], urgent: bool(header[0].urgent), chargeable: bool(header[0].chargeable), canCancel: bool(header[0].canCancel), timeline, costLines, photos, notified };
};

/** The list row for one rescue (same shape as GET /portal/rescue items). */
async function oneRow(userId, rescueNo) {
  const { sets } = await rescueModel.list(userId, { q: rescueNo, status: null, page: 1, pageSize: 5 });
  const row = (sets[0] || []).find((x) => x.rescueNo === rescueNo);
  if (!row) throw new ApiError('NOT_FOUND', 'Rescue not found.');
  return rescueRow(row);
}

const options = asyncHandler(async (req, res) => {
  const [header, units, problemTypes] = (await rescueModel.options(uid(req))).sets.map(isoDeep);
  respond(res, { ...header[0], units, problemTypes });
});

const list = asyncHandler(async (req, res) => {
  const pg = paging(req.query);
  const { sets } = await rescueModel.list(uid(req), { q: opt(req.query.q), status: opt(req.query.status), page: pg.page, pageSize: pg.pageSize || 8 });
  respond(res, { items: (sets[0] || []).map(rescueRow), total: Number(sets[1][0].total), page: pg.page, pageSize: pg.pageSize || 8 });
});

const get = asyncHandler(async (req, res) => respond(res, details((await rescueModel.get(uid(req), str(req.params.rescueNo))).sets)));

const create = asyncHandler(async (req, res) => {
  const b = req.body;
  const name = str(b.sceneContactName); const phone = str(b.sceneContactPhone);
  check([['sceneContactName', name !== '', 'Required'], ['sceneContactPhone', RE.phPhone.test(phone), 'Enter a PH number, e.g. 0917 123 4567']]);
  const { out } = await rescueModel.create(uid(req), {
    chassisNo: str(b.chassisNo), locationText: str(b.locationText), lat: num(b.lat), lng: num(b.lng), problemType: opt(b.problemType), problemDetail: opt(b.problemDetail),
    incident: str(b.incident), loadStatus: opt(b.loadStatus), sceneContactName: crypto.encrypt(name), sceneContactPhone: crypto.encrypt(phone),
    urgent: b.urgent === true, photos: Array.isArray(b.photos) ? b.photos.filter((p) => RE.uuid.test(p)) : [],
  }, source(req));
  log.info(`Rescue ${out.o_rescue_no} requested: ${str(b.chassisNo)} ${opt(b.problemType) || ''}${b.urgent === true ? ' URGENT' : ''} user=${uid(req)}`);
  respond(res, { ...(await oneRow(uid(req), out.o_rescue_no)), warning: out.o_warning || null }, 201);
});

const cancel = asyncHandler(async (req, res) => {
  const no = str(req.params.rescueNo);
  await rescueModel.cancel(uid(req), no, str(req.body.reason), source(req));
  log.info(`Rescue ${no} cancelled by the client user=${uid(req)}`);
  respond(res, await oneRow(uid(req), no));
});

module.exports = { options, list, get, create, cancel };
