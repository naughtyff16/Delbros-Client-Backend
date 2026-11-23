// EWA procedures (05_sp_ewa.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  options: (userId) => call('sp_ewa_options', [userId], ERR),
  list: (userId, q) => call('sp_ewa_list', [userId, q.q, q.qLicenceHash, q.status, q.from, q.to, q.page, q.pageSize], ERR),
  get: (userId, euNo) => call('sp_ewa_get', [userId, euNo], ERR),
  create: (userId, e, src) => call('sp_ewa_create', [userId, e.contractNo, e.branchCode, e.trucker, e.truckPlateNo, e.truckOrcr, e.driverName, e.driverLicenseNo,
    e.driverLicenseHash, e.expectedPickupAt, e.remarks, e.units, src], ['o_eu_no', ...ERR_F]),
  cancel: (userId, euNo, reason, src) => call('sp_ewa_cancel', [userId, euNo, reason, src], ERR_F),
  extension: (userId, euNo, reason, src) => call('sp_ewa_request_extension', [userId, euNo, reason, src], ERR_F),
  resendEmail: (userId, euNo, src) => call('sp_ewa_resend_email', [userId, euNo, src], ERR),
};
