// Rescue procedures (06_sp_rescue.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  options: (userId) => call('sp_rescue_options', [userId], ERR),
  list: (userId, q) => call('sp_rescue_list', [userId, q.q, q.status, q.page, q.pageSize], ERR),
  get: (userId, no) => call('sp_rescue_get', [userId, no], ERR),
  create: (userId, r, src) => call('sp_rescue_create', [userId, r.chassisNo, r.locationText, r.lat, r.lng, r.problemType, r.problemDetail, r.incident, r.loadStatus,
    r.sceneContactName, r.sceneContactPhone, r.urgent, r.photos, src], ['o_rescue_no', 'o_warning', ...ERR_F]),
  cancel: (userId, no, reason, src) => call('sp_rescue_cancel', [userId, no, reason, src], ERR_F),
};
