// E-wallet, top-ups, cash bond (08_sp_ewallet_bond.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  ledger: (userId, q) => call('sp_ewallet_ledger', [userId, q.category, q.from, q.to, q.page, q.pageSize], ERR),
  topups: (userId) => call('sp_topup_list', [userId], ERR),
  topupCreate: (userId, t, src) => call('sp_topup_create', [userId, t.amount, t.transferDate, t.method, t.sendingBank, t.reference, t.proofFileId, t.remarks, t.resubmitOf,
    t.checkNo, t.checkDate, t.checkBank, src], ['o_topup_id', ...ERR_F]),
  cashBonds: (userId) => call('sp_portal_cash_bonds', [userId], ERR),
  refundPreview: (userId, bondId) => call('sp_bond_refund_preview', [userId, bondId], ERR),
  withdrawal: (userId, bondId, w, src) => call('sp_bond_withdrawal_request', [userId, bondId, w.amount, w.reason, w.earlyException, src], ['o_withdrawal_id', ...ERR_F]),
};
