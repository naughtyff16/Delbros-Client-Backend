// Client portal: reference data, dashboard, notifications, feedback, return requests.
const portalModel = require('../models/portalModel');
const { asyncHandler, respond } = require('./errorController');
const { str, num, opt, date, check, source } = require('./helpers');
const log = require('../config/logger').getLogger('portal'); // internal ids only — no personal data

const uid = (req) => req.session.userId;
const yes = (v) => v === true || v === 1 || v === '1';  // MySQL TINYINT / comparison results → boolean

// Weekly billing week from fin.weekly_cycle_start (same rule as the portal: Friday → Friday–Thursday).
const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
function weeklyCycle(start = 'Friday') {
  const i = Math.max(0, WEEKDAYS.indexOf(start));
  return { start: WEEKDAYS[i], end: WEEKDAYS[(i + 6) % 7], startIndex: i, label: `${WEEKDAYS[i]}–${WEEKDAYS[(i + 6) % 7]}` };
}

// GET /ref
const ref = asyncHandler(async (req, res) => {
  const { sets } = await portalModel.refAll(uid(req));
  respond(res, { branches: sets[0], equipmentTypes: sets[1], settings: Object.fromEntries((sets[2] || []).map((s) => [s.key, s.type === 'number' ? Number(s.value) : s.value])) });
});

// GET /portal/dashboard — 12 result sets → one object for the dashboard screen.
const dashboard = asyncHandler(async (req, res) => {
  const [summary, aging, ewallet, walletTxns, cashBond, onHire, returns, returnBranches, openRescues, ewas, contracts, charges] = (await portalModel.dashboard(uid(req))).sets;
  const s = summary[0] || {};
  const bond = cashBond[0] || {};
  const billing = s.billing || {};
  respond(res, {
    ...s,
    oldestDueOverdue: yes(s.oldestDueOverdue), oldestDueInvoices: s.oldestDueInvoices || [],
    activeContracts: { count: s.activeContracts, nearestExpiry: s.nearestExpiry },
    billing: { creditTermBasis: billing.creditTermBasis || 'invoice_date', weekly: weeklyCycle(billing.weeklyCycleStart) },
    aging: aging[0], ewallet: ewallet[0] || null, walletTxns,
    cashBond: { ...bond, withdrawalPending: yes(bond.withdrawalPending) },
    onHire: onHire.map((u) => ({ ...u, canRequestReturn: yes(u.canRequestReturn) })),
    returns: returns.map((r) => ({ ...r, crossBranch: yes(r.crossBranch), isForceInbound: yes(r.isForceInbound), damage: r.damage || [] })),
    returnBranches,
    openRescues: openRescues.map((r) => ({ ...r, urgent: yes(r.urgent) })),
    ewas: ewas.map((e) => ({ ...e, units: e.units || [] })),
    contracts, charges,
  });
});

const notifications = asyncHandler(async (req, res) => respond(res, { items: (await portalModel.notifications(uid(req))).sets[0]
  .map((n) => ({ ...n, id: String(n.id), read: yes(n.read), requiresAck: yes(n.requiresAck) })) }));

const markRead = asyncHandler(async (req, res) => {
  await portalModel.markRead(uid(req), num(req.body.id));
  res.status(204).end();
});

const feedbackSubmit = asyncHandler(async (req, res) => {
  const b = req.body;
  const { sets } = await portalModel.feedbackSubmit(uid(req), { category: str(b.category), subject: opt(b.subject), message: opt(b.message), reference: opt(b.reference),
    rating: num(b.rating), topic: opt(b.topic) }, source(req));
  log.info(`Feedback ${sets[0][0].id} from ${uid(req)}${sets[0][0].rating ? ` (${sets[0][0].rating} stars)` : ''}`);
  respond(res, sets[0][0], 201);
});

const feedbackList = asyncHandler(async (req, res) => respond(res, { items: (await portalModel.feedbackList(uid(req))).sets[0] }));

// POST /portal/returns
const requestReturn = asyncHandler(async (req, res) => {
  const b = req.body;
  check([['chassisNo', str(b.chassisNo) !== '', 'Required'], ['returnBranchCode', str(b.returnBranchCode) !== '', 'Required'], ['preferredDate', !!date(b.preferredDate), 'Required']]);
  const { sets } = await portalModel.returnRequest(uid(req), { chassisNo: str(b.chassisNo), returnBranchCode: str(b.returnBranchCode), preferredDate: date(b.preferredDate), notes: opt(b.notes) }, source(req));
  log.info(`Return request ${sets[0][0].requestNo} for ${sets[0][0].chassisNo} → ${sets[0][0].returnBranchCode} user=${uid(req)}`);
  respond(res, { ...sets[0][0], crossBranch: yes(sets[0][0].crossBranch), notified: sets[1] || [] }, 201);
});

module.exports = { ref, dashboard, notifications, markRead, feedbackSubmit, feedbackList, requestReturn };
