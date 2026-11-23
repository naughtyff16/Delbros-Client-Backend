// Sign-in (email + password, optional email one-time code), session, CSRF, password change and reset.
const config = require('../config');
const crypto = require('./cryptoController');
const mail = require('./mailController');
const authModel = require('../models/authModel');
const { ApiError, asyncHandler, respond } = require('./errorController');
const { RE, str, check, passwordProblem, source } = require('./helpers');
const log = require('../config/logger').getLogger('auth'); // internal ids only — no personal data

// ── Middleware ───────────────────────────────────────────────────────────────────────────────────
/** requireAuth() = any portal user; requireAuth('CLIENT_PORTAL' | 'VENDOR_PORTAL') = that portal only. */
const requireAuth = (realm) => (req, res, next) => {
  if (!req.session.userId) return next(new ApiError('UNAUTHENTICATED', 'Your session has ended. Please sign in again.'));
  if (realm && req.session.realm !== realm) return next(new ApiError('FORBIDDEN', realm === 'VENDOR_PORTAL' ? 'Vendor access only.' : 'Client access only.'));
  return next();
};

/** Double-submit CSRF check on every state-changing request (token from GET /auth/csrf, sent in X-CSRF-Token). */
const verifyCsrf = (req, res, next) => {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
  const token = req.get('x-csrf-token');
  if (!token || !req.session.csrf || token !== req.session.csrf) return next(new ApiError('CSRF_FAILED', 'Your page has expired. Reload and try again.'));
  return next();
};

const csrf = (req, res) => {
  req.session.csrf ??= crypto.randomToken(24);
  respond(res, { csrfToken: req.session.csrf });
};

// Sign-in policy (cached for a minute; it is read on every sign-in).
let policyCache = null; let policyAt = 0;
async function getPolicy() {
  if (!policyCache || Date.now() - policyAt > 60_000) { policyCache = (await authModel.policy()).sets[0][0]; policyAt = Date.now(); }
  return policyCache;
}
const release = require('../config/releaseContacts.json');
/** Support contacts: approved release contacts win over the System-settings values. */
const supportOf = (p) => ({
  client: { role: 'Delbros Client Support', phone: release.client.phone || p.clientSupportPhone, email: release.client.email || p.clientSupportEmail },
  vendor: { role: 'Delbros Procurement', phone: release.vendor.phone || p.vendorSupportPhone, email: release.vendor.email || p.vendorSupportEmail },
});
const policy = asyncHandler(async (req, res) => {
  const p = await getPolicy();
  // payees: the receiving account per billing entity (DBL / NAK / KNX); payee = the Delbros Leasing default.
  respond(res, { ...p, support: supportOf(p), dpoEmail: release.dpoEmail || p.dpoEmail, payees: release.payees, payee: release.payees.DBL });
});
/** DEVELOPMENT ONLY (DEV_EXPOSE_CODES): add the emailed secret to the response for the portal demo box. Never logged. */
const dev = (extra) => (config.devExposeCodes ? extra : {});

/** New session id on sign-in (prevents session fixation); the CSRF token is carried over. */
function startSession(req, profile) {
  return new Promise((resolve, reject) => {
    const csrfToken = req.session.csrf;
    req.session.regenerate((err) => {
      if (err) return reject(err);
      req.session.userId = profile.userId;
      req.session.realm = profile.realm;
      req.session.csrf = csrfToken || crypto.randomToken(24);
      return resolve(req.session.csrf);
    });
  });
}

// ── POST /auth/login ─────────────────────────────────────────────────────────────────────────────
const login = asyncHandler(async (req, res) => {
  const email = str(req.body.email); const password = String(req.body.password || '');
  const realm = req.body.portal === 'vendor' ? 'VENDOR_PORTAL' : 'CLIENT_PORTAL';
  check([['email', RE.email.test(email), 'Enter your email'], ['password', password.length > 0, 'Enter your password']]);
  const p = await getPolicy();
  const src = source(req);

  const { sets } = await authModel.loginLookup(crypto.blindIndex('email', email), realm);
  const user = sets[0][0]; const other = sets[1] && sets[1][0];
  if (user && user.isLocked) log.warn(`Sign-in refused: ${user.userId} is locked`);
  const contact = supportOf(p)[realm === 'VENDOR_PORTAL' ? 'vendor' : 'client']; // generic support only — the password is not verified yet
  if (user && user.isLocked) throw new ApiError('ACCOUNT_LOCKED', 'This account is locked after too many failed sign-in attempts. Try again later or reset your password.', undefined, { lockedUntil: user.lockedUntil, contact });

  const ok = await crypto.verifyPassword(password, user ? user.passwordHash : crypto.DUMMY_HASH);
  if (!user || !ok) {
    if (!user && other && (await crypto.verifyPassword(password, other.passwordHash))) {
      log.info(`Sign-in on the wrong portal tab: ${other.userId}`);
      throw new ApiError('WRONG_PORTAL', `This email is registered for the ${other.realm === 'VENDOR_PORTAL' ? 'Vendor / supplier' : 'Client'} portal. Switch to that tab and sign in again.`, undefined, { realm: other.realm });
    }
    if (user) {
      const { out } = await authModel.loginFailed(user.userId, src);
      log.warn(`Sign-in failed: ${user.userId} wrong password (attempt ${out.o_failed}/${out.o_max})${out.o_locked_until ? ' — account LOCKED' : ''}`);
      if (out.o_locked_until) throw new ApiError('ACCOUNT_LOCKED', `Too many failed sign-ins. The account is locked for ${out.o_lockout_minutes} minutes — or reset your password.`, undefined, { lockedUntil: out.o_locked_until, contact });
    }
    if (!user) log.warn('Sign-in failed: unknown account');
    throw new ApiError('INVALID_CREDENTIALS', 'The email or password is incorrect.', undefined, { maxFailed: p.maxFailed, lockoutMinutes: p.lockoutMinutes });
  }

  const access = await authModel.accessCheck(user.userId, src);
  if (access.out.o_err_code) log.info(`Sign-in refused: ${user.userId} ${access.out.o_err_code}`);
  if (access.out.o_err_code) throw new ApiError(access.out.o_err_code, access.out.o_err_msg, undefined, { contact: access.out.o_contact });

  if (p.secondFactor === 'off') {
    const profile = (await authModel.loginSuccess(user.userId, 'None', src)).sets[0][0];
    const csrfToken = await startSession(req, profile);
    log.info(`Signed in: ${profile.userId} (${profile.realm}, no second factor)`);
    return respond(res, { status: 'signed_in', user: profile, csrfToken });
  }
  // Email one-time code: only its hash is stored; the code goes straight to the user's (decrypted) email.
  const challengeId = crypto.randomToken(24); const code = crypto.randomDigits(6);
  const { out } = await authModel.otpCreate(user.userId, challengeId, crypto.sha256(code), src);
  await mail.sendDirect({ entityType: 'user', entityId: user.userId, event: 'auth.otp', audience: realm === 'VENDOR_PORTAL' ? 'Vendor' : 'Client', label: 'Sign-in code',
    toEnc: out.o_email, subject: 'Your Delbros sign-in code',
    text: `Your Delbros portal sign-in code is ${code}.\nIt expires in ${p.otpMinutes} minutes.\n\nIf you did not try to sign in, change your password.` });
  log.info(`Sign-in code sent: ${user.userId}`);
  return respond(res, { status: 'otp_required', challengeId, maskedEmail: crypto.maskEmail(crypto.decrypt(out.o_email)), expiresAt: out.o_expires_at, resendAfterSeconds: p.otpResendSeconds, ...dev({ devCode: code }) });
});

const verifyOtp = asyncHandler(async (req, res) => {
  check([['code', /^\d{6}$/.test(str(req.body.code)), 'Enter the 6-digit code']]);
  const { sets } = await authModel.otpVerify(str(req.body.challengeId), crypto.sha256(str(req.body.code)), source(req));
  const profile = sets[0][0];
  const csrfToken = await startSession(req, profile);
  log.info(`Signed in: ${profile.userId} (${profile.realm}, email code)`);
  respond(res, { status: 'signed_in', user: profile, csrfToken });
});

const resendOtp = asyncHandler(async (req, res) => {
  const code = crypto.randomDigits(6); const p = await getPolicy();
  const { out } = await authModel.otpResend(str(req.body.challengeId), crypto.sha256(code), source(req));
  await mail.sendDirect({ entityType: 'otp', entityId: 'resend', event: 'auth.otp', audience: 'Client', label: 'Sign-in code', toEnc: out.o_email,
    subject: 'Your new Delbros sign-in code', text: `Your new Delbros portal sign-in code is ${code}.\nIt expires in ${p.otpMinutes} minutes.` });
  log.info('Sign-in code resent');
  respond(res, { expiresAt: out.o_expires_at, resendAfterSeconds: out.o_resend_after_seconds, ...dev({ devCode: code }) });
});

const me = asyncHandler(async (req, res) => respond(res, (await authModel.me(req.session.userId)).sets[0][0]));

const logout = asyncHandler(async (req, res) => {
  const userId = req.session.userId;
  if (userId) { await authModel.sessionEnd(userId, 'signed_out', null, source(req)); log.info(`Signed out: ${userId}`); }
  req.session.destroy(() => { res.clearCookie(config.session.cookieName); res.status(204).end(); });
});

const sessionExpired = asyncHandler(async (req, res) => {
  const userId = req.session.userId;
  if (userId) log.info(`Session expired (idle): ${userId}`);
  if (userId) await authModel.sessionEnd(userId, 'idle', parseInt(req.body.idleMinutes, 10) || config.session.idleMinutes, source(req));
  req.session.destroy(() => { res.clearCookie(config.session.cookieName); res.status(204).end(); });
});

const changePassword = asyncHandler(async (req, res) => {
  const current = String(req.body.currentPassword || ''); const next = String(req.body.newPassword || '');
  const p = await getPolicy();
  const problem = passwordProblem(next, p.passwordMinLength);
  check([['current', current.length > 0, 'Required'], ['next', !problem, problem]]);
  const hash = (await authModel.passwordHash(req.session.userId)).sets[0][0]?.passwordHash;
  if (!(await crypto.verifyPassword(current, hash))) log.warn(`Change password refused: ${req.session.userId} wrong current password`);
  if (!(await crypto.verifyPassword(current, hash))) throw new ApiError('VALIDATION_FAILED', 'The current password is incorrect.', { current: 'Incorrect password' });
  if (await crypto.verifyPassword(next, hash)) throw new ApiError('VALIDATION_FAILED', 'Choose a password different from your current one.', { next: 'Same as the current password' });
  await authModel.changePassword(req.session.userId, await crypto.hashPassword(next), source(req));
  log.info(`Password changed: ${req.session.userId}`);
  res.status(204).end();
});

// ── Forgot / reset password ──────────────────────────────────────────────────────────────────────
const forgotPassword = asyncHandler(async (req, res) => {
  const email = str(req.body.email);
  check([['email', RE.email.test(email), 'Enter your email']]);
  const token = crypto.randomToken(32);
  const p = await getPolicy();
  const { out } = await authModel.resetRequest(crypto.blindIndex('email', email), crypto.sha256(token), source(req));
  if (out.o_user_found) {
    await mail.sendDirect({ entityType: 'user', entityId: out.o_user_id, event: 'auth.password_reset', audience: 'Client', label: 'Password reset link',
      recipientNameEnc: out.o_name, toEnc: out.o_email, subject: 'Reset your Delbros portal password',
      text: `Open this link to choose a new password (valid for ${p.resetLinkMinutes} minutes, single use):\n${config.portalUrl}/reset-password?token=${token}\n\nIf you did not ask for this, ignore this email.` });
  }
  log.info(out.o_user_found ? `Password reset link sent: ${out.o_user_id}` : 'Password reset requested for an unknown account');
  // Same answer whether or not the email exists (no account enumeration).
  respond(res, { message: 'If this email has a portal account, a reset link is on its way.', expiresInMinutes: p.resetLinkMinutes,
    ...(out.o_user_found ? dev({ devResetToken: token }) : {}) }, 202);
});

const checkReset = asyncHandler(async (req, res) => {
  const { sets } = await authModel.resetCheck(crypto.sha256(str(req.params.token)));
  const { currentHash, ...info } = sets[0][0]; // never send the hash to the browser
  respond(res, info);
});

const resetPassword = asyncHandler(async (req, res) => {
  const tokenHash = crypto.sha256(str(req.body.token)); const next = String(req.body.newPassword || '');
  const info = (await authModel.resetCheck(tokenHash)).sets[0][0];
  const problem = passwordProblem(next, info.minLength);
  check([['password', !problem, problem]]);
  if (await crypto.verifyPassword(next, info.currentHash)) throw new ApiError('VALIDATION_FAILED', 'Choose a password different from your current one.', { password: 'Same as the current password' });
  await authModel.resetComplete(tokenHash, await crypto.hashPassword(next), source(req));
  log.info(`Password reset completed: ${info.userId}`);
  respond(res, { email: info.email, realm: info.realm }); // email is ciphertext here; respond() decrypts it for the reset page
});

module.exports = { requireAuth, verifyCsrf, csrf, policy, getPolicy, login, verifyOtp, resendOtp, me, logout, sessionExpired, changePassword, forgotPassword, checkReset, resetPassword };
