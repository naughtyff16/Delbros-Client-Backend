// Auth area: sign-in refusals, email one-time code, development codes, password reset / change, access request, files (stored on the server).
process.env.AWS_SECRET_ACCESS_KEY = process.env.AWS_SECRET_ACCESS_KEY || 'test';
const { test, after, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const h = require('./harness');
const config = require('../App/config');
const authModel = require('../App/models/authModel');
const portalModel = require('../App/models/portalModel');
const mail = require('../App/controllers/mailController');
const { crypto } = h;

// One policy object for the whole file: the controller caches it for a minute, so tests change its fields in place.
const POLICY = { maxFailed: 5, lockoutMinutes: 30, passwordMinLength: 10, sessionTimeoutMinutes: 15, secondFactor: 'email_otp', otpMinutes: 5, otpResendSeconds: 30,
  resetLinkMinutes: 30, registrationExtras: 'tin,consent', clientSupportPhone: '02 8888 0000', clientSupportEmail: 'support@delbros.test', vendorSupportPhone: '', vendorSupportEmail: '', dpoEmail: '' };
const PROFILE = { userId: 'U-000001', realm: 'CLIENT_PORTAL', clientCode: 'C-00123', name: crypto.encrypt('Ana Cruz'), email: crypto.encrypt('ana@client.ph'), roles: ['CLIENT'], status: 'Active' };
const USER = { userId: 'U-000001', realm: 'CLIENT_PORTAL', passwordHash: 'x', isLocked: 0 };

const sent = [];
function base() {
  h.stub(authModel, 'policy', async () => h.ok([[POLICY]]));
  h.stub(mail, 'sendDirect', async (m) => { sent.push(m); return true; });
}
afterEach(() => { h.restore(); sent.length = 0; config.devExposeCodes = false; POLICY.secondFactor = 'email_otp'; });
after(h.stop);

const login = (c, extra = {}) => c.post('/auth/login', { email: 'ana@client.ph', password: 'Secret123!', portal: 'client', ...extra });

test('policy: support contacts, payees and extras (no personal data)', async () => {
  base();
  const r = await h.client().get('/auth/policy');
  assert.equal(r.status, 200);
  assert.equal(r.body.support.client.phone, '02 8888 0000');
  assert.ok(r.body.payees.DBL && r.body.payees.NAK);
  assert.equal(r.body.registrationExtras, 'tin,consent');
});

test('email code sign-in: code emailed, never in the response; verify signs in', async () => {
  base();
  h.stub(authModel, 'loginLookup', async () => h.ok([[USER], []]));
  h.stub(crypto, 'verifyPassword', async () => true);
  h.stub(authModel, 'accessCheck', async () => h.ok([], {}));
  h.stub(authModel, 'otpCreate', async () => h.ok([], { o_expires_at: new Date(Date.now() + 300000), o_email: crypto.encrypt('ana@client.ph') }));
  const c = h.client();
  const r = await login(c);
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'otp_required');
  assert.equal(r.body.devCode, undefined);
  assert.match(r.body.maskedEmail, /\*/);
  assert.equal(sent.length, 1);
  const code = sent[0].text.match(/\b(\d{6})\b/)[1];
  let hash;
  h.stub(authModel, 'otpVerify', async (id, codeHash) => { hash = codeHash; return h.ok([[PROFILE]]); });
  const v = await c.post('/auth/otp/verify', { challengeId: r.body.challengeId, code });
  assert.equal(v.status, 200);
  assert.equal(hash, crypto.sha256(code));                       // only the hash goes to the database
  assert.equal(v.body.user.email, 'ana@client.ph');              // decrypted for the signed-in user
  h.stub(authModel, 'me', async () => h.ok([[PROFILE]]));
  assert.equal((await c.get('/auth/me')).body.name, 'Ana Cruz');
});

test('DEV_EXPOSE_CODES: the emailed code is also returned (development only)', async () => {
  base();
  config.devExposeCodes = true;
  h.stub(authModel, 'loginLookup', async () => h.ok([[USER], []]));
  h.stub(crypto, 'verifyPassword', async () => true);
  h.stub(authModel, 'accessCheck', async () => h.ok([], {}));
  h.stub(authModel, 'otpCreate', async () => h.ok([], { o_expires_at: new Date(), o_email: crypto.encrypt('ana@client.ph') }));
  const r = await login(h.client());
  assert.match(r.body.devCode, /^\d{6}$/);
  assert.ok(sent[0].text.includes(r.body.devCode));
});

test('wrong password: INVALID_CREDENTIALS with the lockout rule; the attempt is counted', async () => {
  base();
  h.stub(authModel, 'loginLookup', async () => h.ok([[USER], []]));
  h.stub(crypto, 'verifyPassword', async () => false);
  const failed = h.stub(authModel, 'loginFailed', async () => h.ok([], { o_failed: 2, o_max: 5, o_locked_until: null, o_lockout_minutes: 30 }));
  const r = await login(h.client(), { password: 'wrong' });
  assert.equal(r.status, 401);
  assert.equal(r.body.code, 'INVALID_CREDENTIALS');
  assert.equal(r.body.details.maxFailed, 5);
  assert.equal(failed.mock.callCount(), 1);
});

test('unknown email: same INVALID_CREDENTIALS answer (no account enumeration)', async () => {
  base();
  h.stub(authModel, 'loginLookup', async () => h.ok([[], []]));
  const r = await login(h.client());
  assert.equal(r.status, 401);
  assert.equal(r.body.code, 'INVALID_CREDENTIALS');
});

test('locked account: ACCOUNT_LOCKED with the unlock time and the support contact', async () => {
  base();
  const until = new Date(Date.now() + 600000);
  h.stub(authModel, 'loginLookup', async () => h.ok([[{ ...USER, isLocked: 1, lockedUntil: until }], []]));
  const r = await login(h.client());
  assert.equal(r.status, 423);
  assert.equal(r.body.code, 'ACCOUNT_LOCKED');
  assert.equal(new Date(r.body.details.lockedUntil).getTime(), until.getTime());
  assert.equal(r.body.details.contact.role, 'Delbros Client Support');
});

test('right password on the wrong portal tab: WRONG_PORTAL', async () => {
  base();
  h.stub(authModel, 'loginLookup', async () => h.ok([[], [{ userId: 'U-000002', realm: 'VENDOR_PORTAL', passwordHash: 'y' }]]));
  h.stub(crypto, 'verifyPassword', async () => true);
  const r = await login(h.client());
  assert.equal(r.status, 409);
  assert.equal(r.body.code, 'WRONG_PORTAL');
  assert.equal(r.body.details.realm, 'VENDOR_PORTAL');
});

test('account state refusal after the right password (e.g. pending approval) carries the contact', async () => {
  base();
  h.stub(authModel, 'loginLookup', async () => h.ok([[USER], []]));
  h.stub(crypto, 'verifyPassword', async () => true);
  h.stub(authModel, 'accessCheck', async () => h.ok([], { o_err_code: 'ACCOUNT_PENDING', o_err_msg: 'Still being reviewed.', o_contact: { role: 'Your Account Executive', email: crypto.encrypt('ae@delbros.test') } }));
  const r = await login(h.client());
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'ACCOUNT_PENDING');
  assert.equal(r.body.details.contact.email, 'ae@delbros.test'); // decrypted for the screen
});

test('forgot password: same answer for an unknown email, nothing sent', async () => {
  base();
  h.stub(authModel, 'resetRequest', async () => h.ok([], { o_user_found: 0 }));
  const r = await h.client().post('/auth/forgot-password', { email: 'nobody@nowhere.ph' });
  assert.equal(r.status, 202);
  assert.equal(r.body.expiresInMinutes, 30);
  assert.equal(r.body.devResetToken, undefined);
  assert.equal(sent.length, 0);
});

test('forgot + reset password: link emailed, reset returns the sign-in email', async () => {
  base();
  config.devExposeCodes = true;
  h.stub(authModel, 'resetRequest', async () => h.ok([], { o_user_found: 1, o_user_id: 'U-000001', o_name: PROFILE.name, o_email: PROFILE.email }));
  const c = h.client();
  const r = await c.post('/auth/forgot-password', { email: 'ana@client.ph' });
  assert.equal(r.status, 202);
  assert.ok(sent[0].text.includes(r.body.devResetToken));
  h.stub(authModel, 'resetCheck', async () => h.ok([[{ userId: 'U-000001', email: PROFILE.email, realm: 'CLIENT_PORTAL', expiresAt: new Date(), minLength: 10, currentHash: 'old' }]]));
  h.stub(crypto, 'verifyPassword', async () => false);
  h.stub(authModel, 'resetComplete', async () => h.ok());
  const check = await c.get(`/auth/reset-password/${r.body.devResetToken}`);
  assert.equal(check.body.email, 'ana@client.ph');
  assert.equal(check.body.currentHash, undefined);               // never sent to the browser
  const done = await c.post('/auth/reset-password', { token: r.body.devResetToken, newPassword: 'NewSecret123' });
  assert.equal(done.status, 200);
  assert.deepEqual(done.body, { email: 'ana@client.ph', realm: 'CLIENT_PORTAL' });
  const weak = await c.post('/auth/reset-password', { token: r.body.devResetToken, newPassword: 'short' });
  assert.equal(weak.status, 422);
  assert.ok(weak.body.fields.password);
});

test('change password: needs a session, a strong new password and the right current one', async () => {
  POLICY.secondFactor = 'off';
  const c = h.client();
  assert.equal((await c.post('/auth/change-password', { currentPassword: 'a', newPassword: 'b' })).status, 401);
  base();
  await h.signIn(c);
  base();
  const weak = await c.post('/auth/change-password', { currentPassword: 'Secret123!', newPassword: 'weak' });
  assert.equal(weak.status, 422);
  assert.ok(weak.body.fields.next);
  h.stub(authModel, 'passwordHash', async () => h.ok([[{ passwordHash: 'h' }]]));
  h.stub(crypto, 'verifyPassword', async () => false);
  const wrong = await c.post('/auth/change-password', { currentPassword: 'nope', newPassword: 'NewSecret123' });
  assert.equal(wrong.status, 422);
  assert.ok(wrong.body.fields.current);
});

test('access request: validated, encrypted before the database, reviewer shown by role only', async () => {
  base();
  let args;
  h.stub(authModel, 'accessRequestCreate', async (r) => { args = r; return h.ok([], { o_reference: 'PAR-000010', o_subject_id: 'C-00200', o_user_id: 'U-000010',
    o_reviewer_label: 'Your Account Executive', o_reviewer_name: crypto.encrypt('Jose Reyes'), o_reviewer_email: crypto.encrypt('jose@delbros.test') }); });
  const c = h.client();
  const bad = await c.post('/access-requests', { clientName: 'A', email: 'x' });
  assert.equal(bad.status, 422);
  assert.ok(bad.body.fields.email && bad.body.fields.phone);
  const body = { accountType: 'client', clientName: 'ACME Trucking', tin: '123-456-789', branchCode: 'MNL', address1: 'Manila', firstName: 'New', lastName: 'Person',
    email: 'New@Acme.ph', phone: '0917 123 4567', password: 'Secret12345', documents: [], consent: true };
  const r = await c.post('/access-requests', body);
  assert.equal(r.status, 201);
  assert.ok(crypto.isEncrypted(args.email) && crypto.isEncrypted(args.tin) && crypto.isEncrypted(args.phone));
  assert.equal(args.emailHash, crypto.blindIndex('email', 'new@acme.ph'));
  assert.equal(r.body.reviewer.name, 'Jose Reyes');
  assert.equal(r.body.notices[0].to, 'Your Account Executive');    // never the reviewer's address
  assert.equal(r.body.notices[0].status, 'Sent');
  assert.equal(r.body.devApprovalLink, undefined);
  assert.ok(/\/access-approval\/[\w-]{20,}/.test(sent[0].text));
});

test('approval link: status label added, documents get links only when clean', async () => {
  base();
  h.stub(authModel, 'approvalGet', async () => h.ok([[{ reference: 'PAR-000010', accountType: 'client', status: 'Submitted', expired: 0 }],
    [{ fileId: 'f1', fileName: 'permit.pdf', scanStatus: 'Pending', storagePath: 'access_doc/2026-11/f1.pdf' }]]));
  const r = await h.client().get('/access-approval/sometoken');
  assert.equal(r.body.statusLabel, 'Pending AE approval');
  assert.equal(r.body.expired, false);
  assert.equal(r.body.documents[0].downloadUrl, null);
  assert.equal(r.body.documents[0].storagePath, undefined); // the server path is never sent to the browser
});

test('files: anonymous upload only for access-request documents', async () => {
  base();
  const reg = h.stub(portalModel, 'fileRegister', async () => h.ok());
  const c = h.client();
  const no = await c.post('/files', { purpose: 'PAYMENT_PROOF', fileName: 'a.pdf', contentType: 'application/pdf', sizeBytes: 100 });
  assert.equal(no.status, 401);
  const bad = await c.post('/files', { purpose: 'ACCESS_DOC', fileName: 'a.exe', contentType: 'application/x-msdownload', sizeBytes: 100 });
  assert.equal(bad.status, 422);
  const big = await c.post('/files', { purpose: 'ACCESS_DOC', fileName: 'a.pdf', contentType: 'application/pdf', sizeBytes: 6 * 1048576 });
  assert.equal(big.status, 422);
  const ok = await c.post('/files', { purpose: 'ACCESS_DOC', fileName: 'permit.pdf', contentType: 'application/pdf', sizeBytes: 100 });
  assert.equal(ok.status, 201);
  assert.equal(ok.body.uploadUrl, `/files/${ok.body.fileId}/content`);
  assert.match(reg.mock.calls[0].arguments[1].storagePath, /^access_doc\/\d{4}-\d{2}\/[0-9a-f-]{36}\.pdf$/); // no personal data in the stored path
  assert.equal(reg.mock.calls[0].arguments[0], null);
});

test('files: upload round trip on the server — session check, content check, sha256, signed download, tampering refused', async () => {
  base();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'delbros-uploads-'));
  const saved = config.files.dir;
  config.files.dir = dir;
  try {
    h.stub(portalModel, 'fileRegister', async () => h.ok());
    const confirm = h.stub(portalModel, 'fileConfirm', async () => h.ok());
    const c = h.client();
    const pdf = Buffer.from('%PDF-1.4 test');
    const p = await c.post('/files', { purpose: 'ACCESS_DOC', fileName: 'permit.pdf', contentType: 'application/pdf', sizeBytes: pdf.length });
    assert.equal(p.status, 201);
    // another browser (no session) cannot write to this upload
    assert.equal((await h.client().raw('PUT', p.body.uploadUrl, pdf, { 'Content-Type': 'application/pdf' })).status, 404);
    // content that is not really a PDF (e.g. a renamed .exe) is refused
    const fake = await c.raw('PUT', p.body.uploadUrl, Buffer.from('MZ not a pdf'), { 'Content-Type': 'application/pdf' });
    assert.equal(fake.status, 422);
    assert.equal(fake.body.fields.file, 'Not a valid PDF, JPG or PNG');
    assert.equal((await c.raw('PUT', p.body.uploadUrl, pdf, { 'Content-Type': 'application/pdf' })).status, 204);
    assert.match(confirm.mock.calls[0].arguments[2], /^[0-9a-f]{64}$/); // sha256 recorded
    // the upload can only be sent once
    assert.equal((await c.raw('PUT', p.body.uploadUrl, pdf, { 'Content-Type': 'application/pdf' })).status, 404);
    const stored = fs.readdirSync(path.join(dir, 'access_doc'), { recursive: true }).find((f) => String(f).endsWith('.pdf'));
    assert.ok(stored);
    const key = ['access_doc', ...String(stored).split(path.sep)].join('/');
    const { downloadLink } = require('../App/controllers/fileController');
    const link = downloadLink(key, 'permit.pdf', null);
    const res = await fetch(`${await h.start()}${link.replace('/api/v1', '')}`);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), '%PDF-1.4 test');
    const bad = await fetch(`${await h.start()}${link.replace('/api/v1', '').replace(/s=[^&]+/, 's=forged')}`);
    assert.equal(bad.status, 404);
    // path traversal in the stored path is refused even with a valid signature
    const evil = downloadLink('../../etc/passwd', 'x.pdf', null);
    assert.equal((await fetch(`${await h.start()}${evil.replace('/api/v1', '')}`)).status, 404);
  } finally {
    config.files.dir = saved;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('ref data is available before sign-in (access-request form)', async () => {
  let who;
  h.stub(portalModel, 'refAll', async (u) => { who = u; return h.ok([[{ code: 'MNL', name: 'Manila Yard', isHeadOffice: 0 }], [], []]); });
  const r = await h.client().get('/ref');
  assert.equal(r.status, 200);
  assert.equal(r.body.branches[0].code, 'MNL');
  assert.equal(who ?? null, null);
});
