// Vendor portal: my POs & invoices, upload an invoice tranche.
const vendorModel = require('../models/vendorModel');
const { asyncHandler, respond } = require('./errorController');
const { RE, str, opt, date, source } = require('./helpers');
const log = require('../config/logger').getLogger('vendor'); // internal ids only — no personal data

const uid = (req) => req.session.userId;
const yes = (v) => v === true || v === 1 || v === '1'; // MySQL TINYINT / EXISTS → boolean

const data = asyncHandler(async (req, res) => {
  const [vendor, pos, lineBalance, receipts, rawInvoices] = (await vendorModel.data(uid(req))).sets;
  const invoices = rawInvoices.map((i) => ({ ...i, resubmitted: yes(i.resubmitted), lines: i.lines || [], history: i.history || [] }));
  respond(res, {
    vendor: vendor[0] || null,
    pos: pos.map((p) => ({ ...p, lineBalance: lineBalance.filter((l) => l.poNo === p.poNo),
      receipts: receipts.filter((r) => r.poNo === p.poNo).map((r) => ({ ...r, lines: r.lines || [] })),
      invoiceTranches: invoices.filter((i) => i.poNo === p.poNo).map(({ id, invoiceNo, invoiceDate, amount, status, lines }) => ({ id, invoiceNo, invoiceDate, amount, status, lines })) })),
    invoices,
  });
});

const uploadInvoice = asyncHandler(async (req, res) => {
  const b = req.body;
  const { sets } = await vendorModel.uploadInvoice(uid(req), { poNo: str(b.poNo), invoiceNo: str(b.invoiceNo), invoiceDate: date(b.invoiceDate),
    fileId: RE.uuid.test(str(b.fileId)) ? str(b.fileId) : null, lines: Array.isArray(b.lines) ? b.lines.map((l) => ({ partCode: str(l.partCode), qty: Number(l.qty) })) : [],
    resubmitOf: opt(b.resubmitOf) }, source(req));
  log.info(`Vendor invoice ${sets[0][0].id} uploaded on ${sets[0][0].poNo}: ${sets[0][0].amount} user=${uid(req)}`);
  respond(res, sets[0][0], 201);
});

module.exports = { data, uploadInvoice };
