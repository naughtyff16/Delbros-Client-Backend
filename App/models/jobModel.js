// Background jobs and the email outbox (11_sp_jobs.sql).
const { call } = require('./procedure');

module.exports = {
  expireEwas: () => call('sp_job_expire_ewas', [], ['o_count']),
  autoHold: () => call('sp_job_auto_hold', [], ['o_count']),
  expireContracts: () => call('sp_job_expire_contracts', [], ['o_notices', 'o_expired']),
  cleanup: () => call('sp_job_cleanup'),
  outboxClaim: (batch) => call('sp_outbox_claim', [batch]),
  outboxMark: (id, ok, providerId, error) => call('sp_outbox_mark', [id, ok ? 1 : 0, providerId, error]),
};
