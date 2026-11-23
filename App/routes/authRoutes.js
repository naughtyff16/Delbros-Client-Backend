// /auth/* and /access-* — public sign-in, password reset, portal access requests.
const express = require('express');
const rateLimit = require('express-rate-limit');
const auth = require('../controllers/authController');
const access = require('../controllers/accessController');

const router = express.Router();
const limit = (max) => rateLimit({ windowMs: 15 * 60 * 1000, max, standardHeaders: true, legacyHeaders: false,
  message: { code: 'RATE_LIMITED', message: 'Too many attempts. Please wait a few minutes and try again.' } });

router.get('/auth/csrf', auth.csrf);
router.get('/auth/policy', auth.policy);
router.post('/auth/login', limit(20), auth.login);
router.post('/auth/otp/verify', limit(20), auth.verifyOtp);
router.post('/auth/otp/resend', limit(10), auth.resendOtp);
router.get('/auth/me', auth.requireAuth(), auth.me);
router.post('/auth/logout', auth.logout);
router.post('/auth/session-expired', auth.sessionExpired);
router.post('/auth/change-password', auth.requireAuth(), auth.changePassword);
router.post('/auth/forgot-password', limit(5), auth.forgotPassword);
router.get('/auth/reset-password/:token', limit(30), auth.checkReset);
router.post('/auth/reset-password', limit(10), auth.resetPassword);

router.post('/access-requests', limit(5), access.create);
router.get('/access-requests/status', limit(30), access.status);
router.get('/access-approval/:token', limit(30), access.approvalGet);
router.post('/access-approval/:token', limit(10), access.approvalDecide);

module.exports = router;
