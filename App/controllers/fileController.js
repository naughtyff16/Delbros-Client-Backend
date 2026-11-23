// Uploaded files are stored on this EC2 server under FILE_DIR (no S3). Flow:
//   1. POST /files { purpose, fileName, contentType, sizeBytes }  → { fileId, uploadUrl: '/files/<id>/content', method: 'PUT' }
//   2. PUT  /files/:fileId/content  (raw file body)               → saved, content checked, marked ready (204)
//   3. the form is submitted with the fileId
// Downloads: GET /files/:fileId returns a short-lived signed link GET /files/download?k=&n=&e=&s= (HMAC with SESSION_SECRET).
//
// Stored paths never contain personal data (purpose/yyyy-mm/<uuid>.<ext>); the original file name is kept in the files table.
// There is no virus scanner: the API checks that the content really is a PDF / JPG / PNG (file signature) and the size limit,
// and never serves files from the web root (FILE_DIR must be outside it).
const nodeCrypto = require('crypto');
const fs = require('fs');
const path = require('path');
const config = require('../config');
const portalModel = require('../models/portalModel');
const { ApiError, asyncHandler, respond } = require('./errorController');
const { str, check } = require('./helpers');
const log = require('../config/logger').getLogger('files'); // internal ids only — no personal data

const TYPES = { 'application/pdf': '.pdf', 'image/jpeg': '.jpg', 'image/png': '.png' };
// File signatures ("magic bytes") — the content must match the declared type.
const SIGNATURES = {
  'application/pdf': (b) => b.subarray(0, 5).toString('latin1') === '%PDF-',
  'image/jpeg': (b) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff,
  'image/png': (b) => b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
};
const maxBytes = () => config.files.maxMb * 1048576;

/** Absolute path of a stored file; refuses anything that would leave FILE_DIR. */
function filePath(storagePath) {
  const root = config.files.dir;
  const p = path.resolve(root, storagePath);
  if (!p.startsWith(root + path.sep)) throw new ApiError('NOT_FOUND', 'File not found.');
  return p;
}
const apiOrigin = (req) => `${req.protocol}://${req.get('host')}${config.apiPrefix}`;
const sign = (s) => nodeCrypto.createHmac('sha256', config.session.secret).update(s).digest('base64url');
const safeName = (n) => String(n).replace(/[^\w.\- ]/g, '_');

/** Short-lived signed download link (no session needed to open it, like a presigned link). */
function downloadLink(storagePath, fileName, req) {
  const e = Math.floor(Date.now() / 1000) + config.files.linkSeconds;
  const n = safeName(fileName);
  const q = new URLSearchParams({ k: storagePath, n, e: String(e), s: sign(`${storagePath}|${n}|${e}`) });
  return `${req ? apiOrigin(req) : config.apiPrefix}/files/download?${q}`;
}

// POST /files — register an upload (anonymous allowed only for ACCESS_DOC; sp_file_register checks purpose / type / size / realm).
const start = asyncHandler(async (req, res) => {
  const userId = req.session.userId || null;
  const purpose = str(req.body.purpose); const fileName = str(req.body.fileName); const contentType = str(req.body.contentType);
  const sizeBytes = Number(req.body.sizeBytes);
  if (!userId && purpose !== 'ACCESS_DOC') throw new ApiError('UNAUTHENTICATED', 'Your session has ended. Please sign in again.');
  check([['file', !!TYPES[contentType], 'PDF, JPG or PNG only'], ['file', sizeBytes > 0 && sizeBytes <= maxBytes(), `Max ${config.files.maxMb} MB`], ['file', fileName.length > 0, 'Required']]);

  const fileId = nodeCrypto.randomUUID();
  const storagePath = `${purpose.toLowerCase()}/${new Date().toISOString().slice(0, 7)}/${fileId}${TYPES[contentType]}`;
  await portalModel.fileRegister(userId, { fileId, storagePath, originalName: path.basename(fileName).slice(0, 255), contentType, sizeBytes, purpose });
  // Only the browser session that started the upload can send its content.
  req.session.uploads = Object.fromEntries([...Object.entries(req.session.uploads || {}), [fileId, { storagePath, contentType }]].slice(-20));
  log.info(`Upload started: ${fileId} ${purpose} ${contentType} ${sizeBytes} bytes user=${userId || 'anonymous'}`);
  respond(res, { fileId, uploadUrl: `/files/${fileId}/content`, method: 'PUT', maxBytes: maxBytes() }, 201);
});

// PUT /files/:fileId/content — raw body (express.raw on this route only): check, save, mark ready.
const content = asyncHandler(async (req, res) => {
  const fileId = str(req.params.fileId);
  const u = (req.session.uploads || {})[fileId];
  if (!u) throw new ApiError('NOT_FOUND', 'Upload not found. Choose the file again.');
  const body = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
  if (!body.length) throw new ApiError('VALIDATION_FAILED', 'The file is empty.', { file: 'Empty file' });
  if (body.length > maxBytes()) throw new ApiError('VALIDATION_FAILED', `Max ${config.files.maxMb} MB.`, { file: `Max ${config.files.maxMb} MB` });
  if (!SIGNATURES[u.contentType]?.(body)) {
    log.warn(`Upload refused: ${fileId} content does not match ${u.contentType}`);
    throw new ApiError('VALIDATION_FAILED', 'This file is not a valid PDF, JPG or PNG.', { file: 'Not a valid PDF, JPG or PNG' });
  }
  const p = filePath(u.storagePath);
  await fs.promises.mkdir(path.dirname(p), { recursive: true });
  const tmp = `${p}.part`;
  await fs.promises.writeFile(tmp, body, { mode: 0o640 });
  await fs.promises.rename(tmp, p);
  const sha256 = nodeCrypto.createHash('sha256').update(body).digest('hex');
  await portalModel.fileConfirm(req.session.userId || null, fileId, sha256);
  delete req.session.uploads[fileId];
  log.info(`Upload stored: ${fileId} (${body.length} bytes)`);
  res.status(204).end();
});

// GET /files/:fileId — signed download link for a file the caller may see (sp_file_get checks ownership and readiness).
const download = asyncHandler(async (req, res) => {
  const f = (await portalModel.fileGet(req.session.userId, str(req.params.fileId))).sets[0][0];
  log.info(`Download link issued: ${str(req.params.fileId)} user=${req.session.userId}`);
  respond(res, { downloadUrl: downloadLink(f.storagePath, f.fileName, req), fileName: f.fileName, contentType: f.contentType, expiresInSeconds: config.files.linkSeconds });
});

// GET /files/download?k=&n=&e=&s= — serve a file from a valid, unexpired signed link.
const serve = asyncHandler(async (req, res) => {
  const k = str(req.query.k); const n = str(req.query.n); const e = Number(req.query.e); const s = str(req.query.s);
  const expected = Buffer.from(sign(`${k}|${n}|${e}`)); const given = Buffer.from(s);
  if (!e || e < Date.now() / 1000 || given.length !== expected.length || !nodeCrypto.timingSafeEqual(given, expected)) throw new ApiError('NOT_FOUND', 'This download link is not valid or has expired.');
  const p = filePath(k);
  if (!fs.existsSync(p)) throw new ApiError('NOT_FOUND', 'File not found.');
  const ext = path.extname(p).toLowerCase();
  res.setHeader('Content-Type', ext === '.pdf' ? 'application/pdf' : ext === '.png' ? 'image/png' : 'image/jpeg');
  res.setHeader('Content-Disposition', `attachment; filename="${safeName(n)}"`);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  fs.createReadStream(p).pipe(res);
});

module.exports = { start, content, download, serve, downloadLink };
