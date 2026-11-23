// /portal/* — client portal (CLIENT_PORTAL sessions only).
const express = require('express');
const { requireAuth } = require('../controllers/authController');
const portal = require('../controllers/portalController');
const ewa = require('../controllers/ewaController');
const rescue = require('../controllers/rescueController');
const billing = require('../controllers/billingController');
const ewallet = require('../controllers/ewalletController');
const contracts = require('../controllers/contractController');

const router = express.Router();
router.use('/portal', requireAuth('CLIENT_PORTAL'));

// Dashboard, notifications, feedback, returns
router.get('/portal/dashboard', portal.dashboard);
router.get('/portal/notifications', portal.notifications);
router.post('/portal/notifications/read', portal.markRead);
router.get('/portal/feedback', portal.feedbackList);
router.post('/portal/feedback', portal.feedbackSubmit);
router.post('/portal/returns', portal.requestReturn);

// EWA
router.get('/portal/ewa/options', ewa.options);
router.get('/portal/ewa', ewa.list);
router.post('/portal/ewa', ewa.create);
router.get('/portal/ewa/:euNo', ewa.get);
router.post('/portal/ewa/:euNo/cancel', ewa.cancel);
router.post('/portal/ewa/:euNo/extension', ewa.extension);
router.post('/portal/ewa/:euNo/resend-email', ewa.resendEmail);

// Rescue
router.get('/portal/rescue/options', rescue.options);
router.get('/portal/rescue', rescue.list);
router.post('/portal/rescue', rescue.create);
router.get('/portal/rescue/:rescueNo', rescue.get);
router.post('/portal/rescue/:rescueNo/cancel', rescue.cancel);

// Invoices & SOA
router.get('/portal/invoices', billing.invoices);
router.get('/portal/invoices/:invoiceNo', billing.invoice);
router.post('/portal/invoices/:invoiceNo/acknowledge', billing.acknowledge);
router.post('/portal/invoices/:invoiceNo/payment-advice', billing.paymentAdvice);
router.post('/portal/invoices/:invoiceNo/dispute', billing.dispute);
router.get('/portal/soa', billing.soa);
router.post('/portal/soa/email', billing.soaEmail);
router.get('/portal/hire-coverage', billing.hireCoverage);

// E-wallet & cash bond
router.get('/portal/ewallet', ewallet.ledger);
router.get('/portal/topups', ewallet.topups);
router.post('/portal/topups', ewallet.topupCreate);
router.get('/portal/cash-bonds', ewallet.cashBonds);
router.get('/portal/cash-bonds/:bondId/refund-preview', ewallet.refundPreview);
router.post('/portal/cash-bonds/:bondId/withdrawals', ewallet.withdrawal);

// Contracts
router.get('/portal/contracts', contracts.list);
router.post('/portal/contracts/:contractNo/requests', contracts.request);

module.exports = router;
