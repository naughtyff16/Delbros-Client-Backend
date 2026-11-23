// /vendor/* — vendor portal (VENDOR_PORTAL sessions only).
const express = require('express');
const { requireAuth } = require('../controllers/authController');
const vendor = require('../controllers/vendorController');

const router = express.Router();
router.use('/vendor', requireAuth('VENDOR_PORTAL'));
router.get('/vendor/portal', vendor.data);
router.post('/vendor/invoices', vendor.uploadInvoice);

module.exports = router;
