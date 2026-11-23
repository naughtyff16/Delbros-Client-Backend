// Test harness for the backend unit tests (node:test, no database, no AWS).
//  - runs the real Express app (routes → controllers) with an in-memory session store
//  - models are stubbed per test: stub(ewaModel, 'list', async () => ({ sets: [...], out: {} }))
//  - client() keeps the session cookie and sends the CSRF token like the browser does
//  - signIn(c, { userId, realm }) signs a client in through POST /auth/login (second factor off)
const os = require('os');
const path = require('path');

process.env.NODE_ENV = 'test';
process.env.SESSION_STORE = 'memory';
process.env.LOG_DIR = path.join(os.tmpdir(), 'delbros-portal-test-logs');
process.env.LOG_LEVEL = process.env.LOG_LEVEL || 'off';
process.env.RUN_JOBS = 'false';
process.env.DEV_EXPOSE_CODES = 'false';
process.env.FILE_DIR = path.join(os.tmpdir(), 'delbros-portal-test-uploads');
process.env.COOKIE_SECURE = 'false';
process.env.CORS_ORIGINS = 'http://localhost:5174';

const { mock } = require('node:test');
const app = require('../App/app');
const authModel = require('../App/models/authModel');
const crypto = require('../App/controllers/cryptoController');

let server; let base;
async function start() {
  if (server) return base;
  await new Promise((resolve) => { server = app.listen(0, '127.0.0.1', resolve); });
  base = `http://127.0.0.1:${server.address().port}/api/v1`;
  return base;
}
async function stop() {
  if (!server) return;
  await new Promise((resolve) => server.close(resolve));
  server = null;
  const pool = require('../App/config/db').pool;
  await pool.end().catch(() => {});
}

/** A browser-like client: cookie jar + CSRF header on POST. */
function client() {
  let cookie = ''; let csrf = '';
  const keep = (res) => { const c = res.headers.getSetCookie?.() || []; if (c.length) cookie = c.map((x) => x.split(';')[0]).join('; '); };
  async function req(method, p, body, extraHeaders = {}) {
    await start();
    if (method !== 'GET' && !csrf && !extraHeaders.noCsrf) {
      const r = await fetch(`${base}/auth/csrf`, { headers: { cookie } }); keep(r); csrf = (await r.json()).csrfToken;
    }
    const { noCsrf, ...h } = extraHeaders;
    const rawBody = Buffer.isBuffer(body); // file content (PUT /files/:id/content) is sent as-is
    const headers = { Accept: 'application/json', ...(cookie ? { cookie } : {}), ...(body !== undefined && !rawBody ? { 'Content-Type': 'application/json' } : {}), ...(method !== 'GET' && csrf && !noCsrf ? { 'X-CSRF-Token': csrf } : {}), ...h };
    const res = await fetch(`${base}${p}`, { method, headers, body: body === undefined ? undefined : rawBody ? body : JSON.stringify(body) });
    keep(res);
    const text = await res.text();
    let json; try { json = text ? JSON.parse(text) : undefined; } catch { json = text; }
    if (json && json.csrfToken) csrf = json.csrfToken;
    return { status: res.status, body: json, headers: res.headers };
  }
  return { get: (p, h) => req('GET', p, undefined, h), post: (p, b = {}, h) => req('POST', p, b, h), raw: req };
}

/** Replace one model / module function for the current test (restored by restore()). */
const stub = (obj, name, impl) => mock.method(obj, name, impl);
const restore = () => mock.restoreAll();

/** Rows helper: rs(row1, row2) → one result set; ok(sets, out) → what models.call() resolves to. */
const ok = (sets = [], out = {}) => ({ sets, out });

/** Sign in through the real login controller with stubbed auth model calls (second factor off). */
async function signIn(c, { userId = 'U-000001', realm = 'CLIENT_PORTAL', clientCode = 'C-00123', vendorId = null } = {}) {
  const profile = { userId, realm, clientCode, vendorId, name: 'Test User', email: 'test.user@example.com', roles: [realm === 'VENDOR_PORTAL' ? 'VENDOR' : 'CLIENT'] };
  const policy = { maxFailed: 5, lockoutMinutes: 30, secondFactor: 'off', otpMinutes: 5, otpResendSeconds: 30, passwordMinLength: 10, resetLinkMinutes: 30, sessionTimeoutMinutes: 15 };
  const m = [
    stub(authModel, 'policy', async () => ok([[policy]])),
    stub(authModel, 'loginLookup', async () => ok([[{ userId, realm, passwordHash: 'x', isLocked: 0 }], []])),
    stub(crypto, 'verifyPassword', async () => true),
    stub(authModel, 'accessCheck', async () => ok([], {})),
    stub(authModel, 'loginSuccess', async () => ok([[profile]])),
  ];
  const r = await c.post('/auth/login', { email: 'test.user@example.com', password: 'Secret123!', portal: realm === 'VENDOR_PORTAL' ? 'vendor' : 'client' });
  for (const x of m) x.mock.restore();
  if (r.status !== 200) throw new Error(`signIn failed: ${r.status} ${JSON.stringify(r.body)}`);
  return profile;
}

module.exports = { start, stop, client, stub, restore, ok, signIn, crypto };
