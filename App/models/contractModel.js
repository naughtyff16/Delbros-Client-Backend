// Contracts and contract change requests (09_sp_contracts.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  list: (userId) => call('sp_portal_contracts', [userId], ERR),
  request: (userId, contractNo, r, src) => call('sp_contract_request_create', [userId, contractNo, r.kind, r.details, r.termMonths, r.changeArea, r.effectiveDate, src], ['o_request_id', ...ERR_F]),
};
