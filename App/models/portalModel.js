// Reference data, files, dashboard, notifications, feedback, returns (04_sp_portal_common.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  refAll: (userId) => call('sp_ref_all', [userId], ERR),
  fileRegister: (userId, f) => call('sp_file_register', [userId, f.fileId, f.storagePath, f.originalName, f.contentType, f.sizeBytes, f.purpose], ERR_F),
  fileConfirm: (userId, fileId, sha256) => call('sp_file_confirm_upload', [userId, fileId, sha256], ERR),
  fileGet: (userId, fileId) => call('sp_file_get', [userId, fileId], ERR),
  dashboard: (userId) => call('sp_portal_dashboard', [userId], ERR),
  notifications: (userId) => call('sp_portal_notifications_list', [userId], ERR),
  markRead: (userId, id) => call('sp_portal_notifications_mark_read', [userId, id], ERR),
  feedbackSubmit: (userId, f, src) => call('sp_portal_feedback_submit', [userId, f.category, f.subject, f.message, f.reference, f.rating, f.topic, src], ['o_feedback_id', ...ERR_F]),
  feedbackList: (userId) => call('sp_portal_feedback_list', [userId], ERR),
  returnRequest: (userId, f, src) => call('sp_portal_return_request', [userId, f.chassisNo, f.returnBranchCode, f.preferredDate, f.notes, src], ['o_request_no', ...ERR_F]),
};
