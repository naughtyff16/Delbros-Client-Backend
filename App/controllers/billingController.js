// Invoices & SOA: list, details, acknowledge, proof of payment, dispute, statement (JSON / CSV), email SOA, hire coverage.
const billingModel = require('../models/billingModel');
const { asyncHandler, respond } = require('./errorController');
const { RE, str, opt, num, date, paging, source } = require('./helpers');
const log = require('../config/logger').getLogger('billing'); // internal ids only — no personal data

const uid = (req) => req.session.userId;

// GET /portal/invoices?view=all — every invoice with its lines, receipts, credit memos, proof of payment and disputes
// (the portal Invoices & SOA page filters in the browser).
const bool = (v) => v === 1 || v === true || v === '1';
async function invoicesAll(req, res) {
  const [rows, lines, payments, credits, advices, disputes] = (await billingModel.invoicesAll(uid(req))).sets;
  const by = (list) => { const m = new Map(); for (const x of list || []) { const { invoiceNo, ...rest } = x; if (!m.has(invoiceNo)) m.set(invoiceNo, []); m.get(invoiceNo).push(rest); } return m; };
  const L = by(lines); const P = by(payments); const C = by(credits); const A = by(advices); const D = by(disputes);
  respond(res, { items: rows.map((i) => ({
    ...i, hasHeld: bool(i.hasHeld), isLease: bool(i.isLease),
    lines: (L.get(i.invoiceNo) || []).map(({ lineNo, dateFrom, dateTo, held, ...l }) => ({ ...l, id: `${i.invoiceNo}-${lineNo}`, from: dateFrom, to: dateTo, held: bool(held) })),
    payments: (P.get(i.invoiceNo) || []).map((p) => ({ ...p, counted: bool(p.counted) })),
    credits: C.get(i.invoiceNo) || [], advices: A.get(i.invoiceNo) || [], disputes: D.get(i.invoiceNo) || [],
  })) });
}

const invoices = asyncHandler(async (req, res) => {
  if (req.query.view === 'all') return invoicesAll(req, res);
  const q = req.query; const pg = paging(q);
  const { sets } = await billingModel.invoices(uid(req), { q: opt(q.q), paymentStatus: opt(q.paymentStatus), billType: opt(q.billType), from: date(q.from), to: date(q.to),
    page: pg.page, pageSize: pg.pageSize || 8 });
  respond(res, { items: sets[0], total: sets[1][0].total, balanceTotal: sets[1][0].balanceTotal, page: pg.page, pageSize: pg.pageSize || 8 });
});

const invoice = asyncHandler(async (req, res) => {
  const [header, lines, payments, memos, paymentAdvices, disputes, history] = (await billingModel.invoice(uid(req), str(req.params.invoiceNo))).sets;
  respond(res, { ...header[0], lines, payments, memos, paymentAdvices, disputes, history });
});

const acknowledge = asyncHandler(async (req, res) => {
  const { out } = await billingModel.acknowledge(uid(req), str(req.params.invoiceNo), source(req));
  log.info(`Invoice ${str(req.params.invoiceNo)} acknowledged, due ${out.o_due_date} user=${uid(req)}`);
  respond(res, { invoiceNo: str(req.params.invoiceNo), dueDate: out.o_due_date, acknowledgedAt: new Date(), acknowledgedBy: uid(req), acknowledgedVia: 'Client portal' });
});

const paymentAdvice = asyncHandler(async (req, res) => {
  const b = req.body;
  const { out } = await billingModel.paymentAdvice(uid(req), str(req.params.invoiceNo), { amount: num(b.amount), paidOn: date(b.paidOn), method: opt(b.method), bank: opt(b.bank),
    reference: opt(b.reference), proofFileId: RE.uuid.test(str(b.proofFileId)) ? str(b.proofFileId) : null, remarks: opt(b.remarks) }, source(req));
  log.info(`Proof of payment ${out.o_advice_id} for ${str(req.params.invoiceNo)} user=${uid(req)}`);
  respond(res, { id: out.o_advice_id, status: 'Submitted' }, 201);
});

const dispute = asyncHandler(async (req, res) => {
  const b = req.body;
  const { out } = await billingModel.dispute(uid(req), str(req.params.invoiceNo), { reason: opt(b.reason), details: str(b.details), amountDisputed: num(b.amountDisputed),
    attachmentFileId: RE.uuid.test(str(b.attachmentFileId)) ? str(b.attachmentFileId) : null }, source(req));
  log.info(`Dispute ${out.o_dispute_id} on ${str(req.params.invoiceNo)} user=${uid(req)}`);
  respond(res, { id: out.o_dispute_id, status: 'Submitted' }, 201);
});

const csvCell = (v) => { const s = v === null || v === undefined ? '' : String(v); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };

// GET /portal/soa?from=&to=&format=json|csv
const soa = asyncHandler(async (req, res) => {
  const [header, rows, notOnStatement, awaitingClearance] = (await billingModel.soa(uid(req), date(req.query.from), date(req.query.to))).sets;
  const h = header[0];
  if (req.query.format === 'csv') {
    const lines = [['Statement of account', h.billingName], ['Period', `${h.periodFrom} to ${h.periodTo}`], ['Balance brought forward', h.balanceBroughtForward], [],
      ['Date', 'Document', 'Number', 'Due', 'Debit', 'Credit', 'Reference', 'Running balance'],
      ...rows.map((r) => [r.date, r.docType, r.docNo, r.due, r.debit, r.credit, r.ref, r.runningBalance]), [], ['Closing balance', h.closingBalance], ['Note', h.scopeNote]];
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="SOA_${h.clientCode}_${h.periodTo}.csv"`);
    return res.send(`﻿${lines.map((l) => l.map(csvCell).join(',')).join('\r\n')}`);
  }
  return respond(res, { header: h, rows, notOnStatement, awaitingClearance });
});

const soaEmail = asyncHandler(async (req, res) => {
  const { sets } = await billingModel.soaEmail(uid(req), date(req.body.from), date(req.body.to), req.body.copyBilling === true, source(req));
  log.info(`SOA ${sets[0][0].soaNo} emailed (${sets[1].length} recipient(s)) user=${uid(req)}`);
  respond(res, { ...sets[0][0], recipients: sets[1], notOnStatement: sets[2] });
});

const hireCoverage = asyncHandler(async (req, res) => {
  const rows = (await billingModel.hireCoverage(uid(req))).sets[0];
  respond(res, { items: rows.map((r) => ({ ...r, missingDays: r.missingDays || [], billedTwiceDays: r.billedTwiceDays || [], invoices: r.invoices || [],
    status: (r.missingDays || []).length ? 'Gap' : (r.billedTwiceDays || []).length ? 'Billed twice' : 'Every day invoiced once' })) });
});

module.exports = { invoices, invoice, acknowledge, paymentAdvice, dispute, soa, soaEmail, hireCoverage };
