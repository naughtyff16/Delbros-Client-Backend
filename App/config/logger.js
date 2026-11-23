// log4js configuration: info log + error log, rotated daily, old files compressed and removed after N days.
//
// PDPA: log files must never contain personal data. Every message goes through sanitize(), which removes
// emails, phone numbers, TIN-like digit runs, ciphertext (enc:…), hashes/tokens and long base64 strings.
// Callers log only internal identifiers (user U-000001, EU-/RSC-/TU- numbers, request id) — never request
// bodies, names, addresses, passwords, codes or tokens. Client IP addresses are not written to the files either
// (the audit trail in the database keeps the source).
const path = require('path');
const fs = require('fs');
const log4js = require('log4js');
const config = require('./index');

const dir = path.resolve(__dirname, '..', '..', config.log.dir);
fs.mkdirSync(dir, { recursive: true });

const layout = { type: 'pattern', pattern: '%d{ISO8601_WITH_TZ_OFFSET} [%p] %c - %m' };
// Rolls by DATE and by SIZE: a new file starts at midnight, and also whenever the current file reaches LOG_MAX_SIZE_MB.
//   app.log (current) → app.2026-11-19.log, app.2026-11-19.1.log, app.2026-11-19.2.log … (older ones compressed to .gz)
// numBackups counts rolled FILES (not days); the oldest are deleted beyond LOG_MAX_FILES / LOG_MAX_ERROR_FILES.
const rolling = (file, maxFiles) => ({
  type: 'dateFile', filename: path.join(dir, file), pattern: 'yyyy-MM-dd', maxLogSize: config.log.maxSizeMb * 1024 * 1024,
  numBackups: maxFiles, compress: true, keepFileExt: true, layout,
});
const appenders = {
  app: rolling('app.log', config.log.maxFiles),
  errorFile: rolling('error.log', config.log.maxErrorFiles),
  errors: { type: 'logLevelFilter', appender: 'errorFile', level: 'error' },
  console: { type: 'console', layout },
};
const use = ['app', 'errors', ...(config.isProduction ? [] : ['console'])];
log4js.configure({ appenders, categories: { default: { appenders: use, level: config.log.level } } });

// ── Personal-data filter ──────────────────────────────────────────────────────────────────────────
const RULES = [
  [/enc:[A-Za-z0-9]+:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+/g, '[encrypted]'],           // ciphertext
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]'],                               // emails
  [/\b[0-9a-f]{32,}\b/gi, '[hash]'],                                                             // hashes, tokens, blind indexes
  [/\b[A-Za-z0-9_-]{40,}\b/g, '[token]'],                                                        // long base64/base64url secrets
  [/(\+63|\b0)\s?\(?\d{1,3}\)?[\s-]?\d{3,4}[\s-]?\d{4}\b/g, '[phone]'],                          // PH phone numbers
  [/\b\d{3}[- ]?\d{3}[- ]?\d{3}([- ]?\d{3,5})?\b/g, '[number]'],                                 // TIN-like digit runs
  [/\b[A-Z]\d{2}-\d{2}-\d{6}\b/g, '[licence]'],                                                  // driver licence
];
function sanitize(value) {
  let s;
  if (value instanceof Error) s = `${value.name}: ${value.message}${value.stack ? `\n${value.stack.split('\n').slice(1).join('\n')}` : ''}`;
  else if (typeof value === 'string') s = value;
  else { try { s = JSON.stringify(value); } catch { s = String(value); } }
  for (const [re, rep] of RULES) s = s.replace(re, rep);
  return s;
}

/** getLogger('auth') → { debug, info, warn, error } — every argument is sanitised before it is written. */
function getLogger(category) {
  const l = log4js.getLogger(category);
  const wrap = (level) => (...args) => l[level](args.map(sanitize).join(' '));
  return { debug: wrap('debug'), info: wrap('info'), warn: wrap('warn'), error: wrap('error') };
}

/** Flush files on shutdown. */
const shutdown = () => new Promise((resolve) => log4js.shutdown(resolve));

module.exports = { getLogger, sanitize, shutdown, logDir: dir };
