// One error format for the whole API: { code, message, fields?, details? } — the shape the frontend ApiError expects.
const { decryptDeep } = require('./cryptoController');
const log = require('../config/logger').getLogger('error');

const STATUS = {
  VALIDATION_FAILED: 422, MISSING_DRIVER_TRUCK_INFO: 422, ENTITLEMENT_EXCEEDED: 422, THRESHOLD_EXCEEDED: 422, EXCESS_INVOICE: 422,
  UNAUTHENTICATED: 401, INVALID_CREDENTIALS: 401, OTP_INVALID: 401,
  FORBIDDEN: 403, ACCOUNT_PENDING: 403, ACCOUNT_INACTIVE: 403, NOT_ACCREDITED: 403, CSRF_FAILED: 403,
  NOT_FOUND: 404, RESET_INVALID: 404, APPROVAL_LINK_INVALID: 404, CLIENT_NOT_FOUND: 404,
  INVALID_STATE: 409, DUPLICATE: 409, ALREADY_DECIDED: 409, WRONG_PORTAL: 409, EMAIL_IN_USE: 409, EMAIL_OTHER_COMPANY: 409, TIN_IN_USE: 409,
  CREDIT_GATE_BLOCKED: 409, ELIGIBILITY: 409, WALLET: 409, NOTHING_REFUNDABLE: 409, BR14_CONTRACT_ACTIVE: 409, FILE_NOT_READY: 409,
  OTP_EXPIRED: 410, RESET_USED: 410, RESET_EXPIRED: 410, APPROVAL_LINK_EXPIRED: 410,
  ACCOUNT_LOCKED: 423, OTP_LOCKED: 429, OTP_WAIT: 429, RATE_LIMITED: 429,
};

class ApiError extends Error {
  constructor(code, message, fields, details, status) {
    super(message);
    this.code = code;
    this.fields = fields || undefined;
    this.details = details || undefined;
    this.status = status || STATUS[code] || 400;
  }
}

/** Wrap async route handlers so rejected promises reach the error handler. */
const asyncHandler = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

// Datetimes nested in JSON_OBJECT / JSON_ARRAYAGG come back as 'YYYY-MM-DD HH:MM:SS.ffffff' with no zone (the database is UTC);
// convert them to ISO UTC so browsers do not read them as local time. Plain DATE strings ('YYYY-MM-DD') are left alone.
const SQL_DT = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?$/;
function isoDeep(v) {
  if (typeof v === 'string' && SQL_DT.test(v)) { const [d, t] = v.split(' '); const [hms, frac = ''] = t.split('.'); return `${d}T${hms}.${(frac + '000').slice(0, 3)}Z`; }
  if (Array.isArray(v)) return v.map(isoDeep);
  if (v && typeof v === 'object' && !(v instanceof Date) && !Buffer.isBuffer(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, isoDeep(x)]));
  return v;
}

/** Send a successful response — personal data is decrypted here, at the last moment, for the signed-in user. */
const respond = (res, data, status = 200) => (data === undefined ? res.status(204).end() : res.status(status).json(decryptDeep(isoDeep(data))));

const notFound = (req, res) => res.status(404).json({ code: 'NOT_FOUND', message: 'Endpoint not found.' });

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  if (err instanceof ApiError) {
    // Expected refusals: the code and the field names only (field messages / details may describe the user's input).
    if (err.status !== 401 && err.status !== 404) log.info(`${req.id} refused ${err.code}${err.fields ? ` fields=${Object.keys(err.fields).join(',')}` : ''} user=${req.session?.userId || '-'}`);
    return res.status(err.status).json({ code: err.code, message: err.message, fields: err.fields, details: err.details ? decryptDeep(err.details) : undefined });
  }
  if (err.type === 'entity.too.large') return res.status(413).json({ code: 'VALIDATION_FAILED', message: 'The file or request is too large (max 5 MB).', fields: { file: 'Max 5 MB' } });
  if (err.type === 'entity.parse.failed') return res.status(400).json({ code: 'VALIDATION_FAILED', message: 'The request body is not valid JSON.' });
  // Unexpected: full error in error.log (sanitised — SQL error texts can echo values), only the reference to the browser.
  const ref = (req.id || Math.random().toString(36).slice(2, 10)).toUpperCase();
  log.error(`${ref} ${req.method} ${req.path} user=${req.session?.userId || '-'}`, err);
  return res.status(500).json({ code: 'INTERNAL', message: `Something went wrong. Please try again (ref ${ref}).` });
}

module.exports = { ApiError, STATUS, asyncHandler, respond, isoDeep, notFound, errorHandler };
