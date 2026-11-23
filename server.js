// Entry point: starts the Express API and (optionally) the background jobs on this EC2 instance.
const config = require('./App/config');
const { getLogger, shutdown, logDir } = require('./App/config/logger');
const app = require('./App/app');
const { startJobs } = require('./App/controllers/jobController');

const log = getLogger('server');

const server = app.listen(config.port, () => {
  log.info(`API listening on port ${config.port} (${config.env}), logs in ${logDir}`);
  // Run jobs on ONE instance only (RUN_JOBS=true there); other instances serve requests only.
  if (config.jobs.enabled) startJobs();
});

process.on('unhandledRejection', (err) => log.error('Unhandled promise rejection', err));
process.on('uncaughtException', (err) => {
  log.error('Uncaught exception — stopping', err);
  shutdown().finally(() => process.exit(1));
});

// Graceful stop (pm2 / systemd send SIGTERM): finish open requests, flush the log files.
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    log.info(`${sig} received — shutting down`);
    server.close(() => shutdown().finally(() => process.exit(0)));
    setTimeout(() => process.exit(0), 10_000).unref();
  });
}
