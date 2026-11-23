// Background work on a timer (roadmap layer 7): EWA expiry, automatic credit hold, contract expiry notices,
// housekeeping and the email outbox sender. Run on ONE instance (RUN_JOBS=true).
const jobModel = require('../models/jobModel');
const { processOutbox } = require('./mailController');
const log = require('../config/logger').getLogger('jobs'); // internal ids only — no personal data

const running = new Set();
/** Run a job, never two copies at once, log failures without stopping the timer. */
async function run(name, fn) {
  if (running.has(name)) return;
  running.add(name);
  try { await fn(); } catch (e) { log.error(`Job ${name} failed`, e); } finally { running.delete(name); }
}

// Daily jobs once per Manila day, after 00:10 PHT.
let lastDaily = '';
async function daily() {
  const manila = new Date(Date.now() + 8 * 3600_000);
  const day = manila.toISOString().slice(0, 10);
  if (day === lastDaily || manila.getUTCHours() * 60 + manila.getUTCMinutes() < 10) return;
  const { out } = await jobModel.expireContracts();
  await jobModel.cleanup();
  lastDaily = day;
  log.info(`Daily jobs ${day}: ${out.o_notices} renewal notice(s), ${out.o_expired} contract(s) expired, cleanup done`);
}

function startJobs() {
  const every = (ms, name, fn) => { setInterval(() => run(name, fn), ms).unref(); run(name, fn); };
  every(30_000, 'outbox', () => processOutbox(25));
  every(5 * 60_000, 'expire-ewas', async () => { const { out } = await jobModel.expireEwas(); if (out.o_count) log.info(`EWA expiry: ${out.o_count} EWA(s) expired`); });
  every(60 * 60_000, 'auto-hold', async () => { const { out } = await jobModel.autoHold(); if (out.o_count) log.warn(`Auto credit hold (BR-02): ${out.o_count} client(s) put on hold`); });
  every(10 * 60_000, 'daily', daily);
  log.info('Background jobs started (outbox 30 s, EWA expiry 5 min, auto hold 60 min, daily 00:10 PHT)');
}

module.exports = { startJobs };
