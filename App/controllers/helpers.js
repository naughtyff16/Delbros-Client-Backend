// Small shared helpers for controllers: input checks (format rules that the database cannot check on
// encrypted values), paging, the audit "source" string.
const { ApiError } = require('./errorController');

const RE = {
  email: /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/,
  phPhone: /^(\+63|0)\s?\(?\d{1,3}\)?[\s-]?\d{3,4}[\s-]?\d{4}$/,      // e.g. 0917 123 4567
  licence: /^[A-Z]\d{2}-\d{2}-\d{6}$/,                                  // LTO, e.g. N01-23-456789
  plate: /^[A-Z]{2,3} ?\d{3,4}$/,                                       // LTO, e.g. NAB 5678
  date: /^\d{4}-\d{2}-\d{2}$/,
  uuid: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
};

const str = (v) => (v === undefined || v === null ? '' : String(v).trim());
const opt = (v) => (str(v) === '' ? null : str(v));
const num = (v) => (v === undefined || v === null || v === '' ? null : Number(v));
const date = (v) => (RE.date.test(str(v)) ? str(v) : null);

/** Collect field errors; throw VALIDATION_FAILED if any. */
function check(rules, message = 'Check the highlighted fields.') {
  const fields = {};
  for (const [field, ok, msg] of rules) if (!ok && !fields[field]) fields[field] = msg;
  if (Object.keys(fields).length) throw new ApiError('VALIDATION_FAILED', message, fields);
}

function passwordProblem(pw, minLength = 10) {
  if (!pw || pw.length < minLength) return `At least ${minLength} characters`;
  if (!/[A-Z]/.test(pw) || !/[a-z]/.test(pw) || !/\d/.test(pw)) return 'Use upper- and lower-case letters and a number';
  return null;
}

const paging = (q) => ({ page: Math.max(1, parseInt(q.page, 10) || 1), pageSize: Math.min(100, Math.max(1, parseInt(q.pageSize, 10) || 0)) || null });

/** Audit source: channel + client IP (behind the ALB, req.ip is correct when TRUST_PROXY=1). */
const source = (req) => `Portal · ${req.ip}`;

module.exports = { RE, str, opt, num, date, check, passwordProblem, paging, source };
