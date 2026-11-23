// /files/* — uploads stored on this server, signed download links; /ref — reference data.
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('../config');
const { requireAuth } = require('../controllers/authController');
const files = require('../controllers/fileController');
const portal = require('../controllers/portalController');

const router = express.Router();
const uploadLimit = rateLimit({ windowMs: 15 * 60 * 1000, max: 60, message: { code: 'RATE_LIMITED', message: 'Too many uploads. Please wait and try again.' } });
const rawFile = express.raw({ type: () => true, limit: `${config.files.maxMb}mb` });

router.post('/files', uploadLimit, files.start);                             // anonymous allowed only for ACCESS_DOC (checked in the controller)
router.put('/files/:fileId/content', uploadLimit, rawFile, files.content);  // the upload must belong to this session
router.get('/files/download', files.serve);                                 // signed, short-lived link (no session needed)
router.get('/files/:fileId', requireAuth(), files.download);
router.get('/ref', portal.ref);                                             // public reference data; a signed-in caller is checked by sp_ref_all

module.exports = router;
