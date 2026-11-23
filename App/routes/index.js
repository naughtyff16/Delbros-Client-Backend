// All routes under /api/v1. CSRF is checked on every state-changing request.
const express = require('express');
const { verifyCsrf } = require('../controllers/authController');

const router = express.Router();
router.get('/health', (req, res) => res.json({ status: 'ok' })); // ALB health check (no database call)
router.use(verifyCsrf);
router.use(require('./authRoutes'));
router.use(require('./fileRoutes'));
router.use(require('./portalRoutes'));
router.use(require('./vendorRoutes'));

module.exports = router;
