// E-wallet ledger, top-up requests, cash bond list / refund preview / withdrawal.
const ewalletModel = require('../models/ewalletModel');
const release = require('../config/releaseContacts.json');
const { asyncHandler, respond } = require('./errorController');
const { RE, str, opt, num, date, paging, source } = require('./helpers');
const log = require('../config/logger').getLogger('ewallet'); // internal ids only — no personal data

const uid = (req) => req.session.userId;

const ledger = asyncHandler(async (req, res) => {
  const q = req.query; const all = q.all === '1';
  const pg = all ? { page: 1, pageSize: 0 } : paging(q);
  const { sets } = await ewalletModel.ledger(uid(req), { category: opt(q.category), from: date(q.from), to: date(q.to), page: pg.page, pageSize: all ? 0 : pg.pageSize || 10 });
  const wallet = sets[0][0] || {};
  respond(res, { wallet, payee: release.payees[wallet.billingEntity] || release.payees.DBL, items: sets[1].map((t) => ({ ...t, postedByTreasury: t.postedByTreasury === 1 || t.postedByTreasury === true })), total: sets[2][0].total, page: pg.page, pageSize: all ? sets[2][0].total : pg.pageSize || 10 });
});

const topups = asyncHandler(async (req, res) => {
  const [rows, notified] = (await ewalletModel.topups(uid(req))).sets;
  respond(res, { items: rows.map((t) => ({ ...t, notified: notified.filter((n) => n.topupId === t.id) })) });
});

const topupCreate = asyncHandler(async (req, res) => {
  const b = req.body;
  const { sets } = await ewalletModel.topupCreate(uid(req), { amount: num(b.amount), transferDate: date(b.transferDate), method: opt(b.method), sendingBank: opt(b.sendingBank),
    reference: opt(b.reference), proofFileId: RE.uuid.test(str(b.proofFileId)) ? str(b.proofFileId) : null, remarks: opt(b.remarks), resubmitOf: opt(b.resubmitOf),
    checkNo: opt(b.checkNo), checkDate: date(b.checkDate), checkBank: opt(b.checkBank) }, source(req));
  log.info(`Top-up ${sets[0][0].id} submitted: ${sets[0][0].amount} by ${sets[0][0].method}${opt(b.resubmitOf) ? ` (resubmits ${opt(b.resubmitOf)})` : ''} user=${uid(req)}`);
  respond(res, { ...sets[0][0], notified: sets[1] }, 201);
});

const cashBonds = asyncHandler(async (req, res) => {
  const [bonds, withdrawals] = (await ewalletModel.cashBonds(uid(req))).sets;
  respond(res, { bonds, withdrawals: withdrawals.map((w) => ({ ...w, earlyException: w.earlyException === 1 || w.earlyException === true, steps: w.steps || [] })) });
});

const refundPreview = asyncHandler(async (req, res) => {
  const p = (await ewalletModel.refundPreview(uid(req), str(req.params.bondId))).sets[0][0];
  respond(res, { ...p, contractEnded: p.contractEnded === 1 || p.contractEnded === true });
});

const withdrawal = asyncHandler(async (req, res) => {
  const { out } = await ewalletModel.withdrawal(uid(req), str(req.params.bondId), { amount: num(req.body.amount), reason: str(req.body.reason), earlyException: req.body.earlyException === true }, source(req));
  log.info(`Cash bond withdrawal ${out.o_withdrawal_id} requested on ${str(req.params.bondId)}: ${num(req.body.amount)} user=${uid(req)}`);
  respond(res, { id: out.o_withdrawal_id, status: 'Pending' }, 201);
});

module.exports = { ledger, topups, topupCreate, cashBonds, refundPreview, withdrawal };
