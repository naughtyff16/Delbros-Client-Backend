// Invoices, SOA, proof of payment, disputes, hire coverage (07_sp_billing.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  invoices: (userId, q) => call('sp_invoice_list', [userId, q.q, q.paymentStatus, q.billType, q.from, q.to, q.page, q.pageSize], ERR),
  invoicesAll: (userId) => call('sp_portal_invoices_all', [userId], ERR),
  invoice: (userId, no) => call('sp_invoice_get', [userId, no], ERR),
  acknowledge: (userId, no, src) => call('sp_invoice_acknowledge', [userId, no, src], ['o_due_date', ...ERR]),
  paymentAdvice: (userId, no, p, src) => call('sp_payment_advice_create', [userId, no, p.amount, p.paidOn, p.method, p.bank, p.reference, p.proofFileId, p.remarks, src], ['o_advice_id', ...ERR_F]),
  dispute: (userId, no, d, src) => call('sp_invoice_dispute_create', [userId, no, d.reason, d.details, d.amountDisputed, d.attachmentFileId, src], ['o_dispute_id', ...ERR_F]),
  soa: (userId, from, to) => call('sp_soa_get', [userId, from, to], ERR_F),
  soaEmail: (userId, from, to, copyBilling, src) => call('sp_soa_email', [userId, from, to, copyBilling, src], ['o_soa_no', ...ERR_F]),
  hireCoverage: (userId) => call('sp_hire_coverage', [userId], ERR),
};
