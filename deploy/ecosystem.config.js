// pm2 process file for the backend on the EC2 server.
//   pm2 start deploy/ecosystem.config.js && pm2 save && pm2 startup   (start again automatically after a reboot)
// One process only: the background jobs (RUN_JOBS=true) must run once.
// All configuration is in App/.env (NODE_ENV, DB, keys, SES, FILE_DIR, LOG_DIR …).
module.exports = {
  apps: [{
    name: 'delbros-portal-api',
    cwd: __dirname + '/..',
    script: 'server.js',
    instances: 1,
    exec_mode: 'fork',
    max_memory_restart: '700M',
    kill_timeout: 12000,          // the server finishes open requests and flushes the logs on SIGTERM (10 s)
    // The application writes its own rolling log files (LOG_DIR). pm2 keeps only start-up failures (e.g. a missing .env value).
    out_file: '/dev/null',
    error_file: '/var/delbros/logs/pm2-startup-error.log',
  }],
};
