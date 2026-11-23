// Sign-in, one-time code, password and access-request procedures (03_sp_auth.sql).
const { call, ERR, ERR_F } = require('./procedure');

module.exports = {
  policy: () => call('sp_auth_policy'),
  loginLookup: (emailHash, realm) => call('sp_auth_login_lookup', [emailHash, realm]),
  loginFailed: (userId, src) => call('sp_auth_login_failed', [userId, src], ['o_failed', 'o_locked_until', 'o_max', 'o_lockout_minutes']),
  accessCheck: (userId, src) => call('sp_auth_access_check', [userId, src], ['o_err_code', 'o_err_msg', 'o_contact'], { raw: true }),
  loginSuccess: (userId, secondFactor, src) => call('sp_auth_login_success', [userId, secondFactor, src]),
  me: (userId) => call('sp_auth_me', [userId]),
  otpCreate: (userId, challengeId, codeHash, src) => call('sp_auth_otp_create', [userId, challengeId, codeHash, src], ['o_expires_at', 'o_resend_after', 'o_email']),
  otpVerify: (challengeId, codeHash, src) => call('sp_auth_otp_verify', [challengeId, codeHash, src], ['o_user_id', ...ERR_F]),
  otpResend: (challengeId, codeHash, src) => call('sp_auth_otp_resend', [challengeId, codeHash, src], ['o_email', 'o_expires_at', 'o_resend_after_seconds', ...ERR]),
  sessionEnd: (userId, reason, idleMinutes, src) => call('sp_auth_session_end', [userId, reason, idleMinutes, src]),
  passwordHash: (userId) => call('sp_auth_password_hash_get', [userId]),
  changePassword: (userId, newHash, src) => call('sp_auth_change_password', [userId, newHash, src]),
  resetRequest: (emailHash, tokenHash, src) => call('sp_auth_reset_request', [emailHash, tokenHash, src], ['o_user_found', 'o_user_id', 'o_name', 'o_email', 'o_expires_at']),
  resetCheck: (tokenHash) => call('sp_auth_reset_check', [tokenHash], ERR),
  resetComplete: (tokenHash, newHash, src) => call('sp_auth_reset_complete', [tokenHash, newHash, src], ERR),
  recordDirectEmail: (m) => call('sp_outbox_record_direct', [m.entityType, m.entityId, m.event, m.audience, m.label, m.recipientName, m.to, m.subject, m.status, m.providerId, m.error]),

  accessRequestCreate: (r) => call('sp_access_request_create', [r.accountType, r.companyName, r.tin, r.tinHash, r.branchCode, r.address, r.firstName, r.lastName, r.fullName,
    r.email, r.emailHash, r.phone, r.passwordHash, r.documents, r.consent, r.approvalTokenHash, r.source],
  ['o_reference', 'o_subject_id', 'o_user_id', 'o_reviewer_label', 'o_reviewer_name', 'o_reviewer_email', ...ERR_F]),
  accessRequestStatus: (reference, emailHash) => call('sp_access_request_status', [reference, emailHash], ERR),
  approvalGet: (tokenHash) => call('sp_access_approval_get', [tokenHash], ERR),
  approvalDecide: (tokenHash, decision, billingName, reason, src) => call('sp_access_approval_decide', [tokenHash, decision, billingName, reason, src], ERR_F),
};
