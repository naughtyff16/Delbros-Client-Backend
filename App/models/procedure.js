// Base model: runs one stored procedure, returns its result sets and OUT parameters.
// Every database access in this backend goes through here (the DB account has EXECUTE only).
const { pool } = require('../config/db');
const { ApiError } = require('../controllers/errorController');
const config = require('../config');
const log = require('../config/logger').getLogger('db');

const NAME_RE = /^sp_[a-z0-9_]+$/;

// JS → SQL parameter: objects/arrays become JSON text, booleans 1/0, undefined NULL.
const toSql = (v) => {
  if (v === undefined) return null;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (v && typeof v === 'object' && !(v instanceof Date) && !Buffer.isBuffer(v)) return JSON.stringify(v);
  return v;
};
// OUT parameters come back as text; JSON ones (o_err_fields, o_contact) are parsed.
const fromOut = (v) => {
  if (typeof v === 'string' && /^[[{]/.test(v)) { try { return JSON.parse(v); } catch { /* plain text */ } }
  return v;
};

/**
 * call('sp_ewa_get', [userId, euNo], ['o_err_code', 'o_err_msg']) → { sets: [[rows], …], out: { o_err_code, … } }
 * Throws ApiError when the procedure returns o_err_code (unless options.raw).
 */
async function call(name, args = [], outs = [], options = {}) {
  if (!NAME_RE.test(name)) throw new Error(`Invalid procedure name ${name}`);
  const started = Date.now();
  let conn;
  try { conn = await pool.getConnection(); } catch (e) { log.error(`Database connection failed (${name})`, e); throw e; }
  try {
    if (outs.length) await conn.query(`SET ${outs.map((o) => `@${o} = NULL`).join(', ')}`);
    const placeholders = [...args.map(() => '?'), ...outs.map((o) => `@${o}`)].join(', ');
    const [result] = await conn.query(`CALL ${name}(${placeholders})`, args.map(toSql));
    const sets = Array.isArray(result) ? result.filter((r) => Array.isArray(r)) : [];
    let out = {};
    if (outs.length) {
      const [rows] = await conn.query(`SELECT ${outs.map((o) => `@${o} AS ${o}`).join(', ')}`);
      out = Object.fromEntries(Object.entries(rows[0]).map(([k, v]) => [k, fromOut(v)]));
    }
    const ms = Date.now() - started;
    // Procedure name, time and result code only — the arguments carry personal data and are never logged.
    if (ms >= config.log.slowProcedureMs) log.warn(`Slow procedure ${name} ${ms}ms`); else log.debug(`${name} ${ms}ms${out.o_err_code ? ` → ${out.o_err_code}` : ''}`);
    if (!options.raw && out.o_err_code) throw new ApiError(out.o_err_code, out.o_err_msg || 'Request refused.', out.o_err_fields || undefined);
    return { sets, out };
  } catch (e) {
    if (!(e instanceof ApiError)) log.error(`Procedure ${name} failed after ${Date.now() - started}ms (MySQL ${e.code || ''} ${e.errno || ''})`, e);
    throw e;
  } finally {
    conn.release();
  }
}

/** Common case: the standard error triple. */
const ERR = ['o_err_code', 'o_err_msg'];
const ERR_F = ['o_err_code', 'o_err_msg', 'o_err_fields'];

module.exports = { call, ERR, ERR_F };
